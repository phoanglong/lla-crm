// LLA CRM — Zalo OA Bridge
// Cầu nối Zalo Official Account ↔ LLA CRM (Chatwoot API channel inbox).
// Zero-dependency Node.js >= 20. MIT — © 2026 LLA.
//
// Luồng vào:  Zalo webhook -> /webhook/zalo -> tạo/tìm contact + hội thoại -> ghi tin nhắn incoming
// Luồng ra:   LLA CRM inbox webhook -> /webhook/chatwoot -> gửi tin ra Zalo CS API
// OAuth:      /oauth/start -> Zalo permission -> /oauth/callback -> lưu token (refresh xoay vòng)
//
// ENV bắt buộc: ZALO_APP_ID, ZALO_APP_SECRET, CHATWOOT_URL, CHATWOOT_API_TOKEN,
//               CHATWOOT_ACCOUNT_ID, CHATWOOT_INBOX_ID, BRIDGE_PUBLIC_URL
// ENV tuỳ chọn: PORT (8787), DATA_DIR (/data), ZALO_VERIFY_SIGNATURE (true)

import { createServer } from "node:http";
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

const ENV = (k, d) => (process.env[k] ?? d ?? "").trim();
const PORT = Number(ENV("PORT", "8787"));
const DATA_DIR = ENV("DATA_DIR", "/data");
const APP_ID = ENV("ZALO_APP_ID");
const APP_SECRET = ENV("ZALO_APP_SECRET");
const CW_URL = ENV("CHATWOOT_URL").replace(/\/$/, "");
const CW_TOKEN = ENV("CHATWOOT_API_TOKEN");
const CW_ACCOUNT = ENV("CHATWOOT_ACCOUNT_ID");
const CW_INBOX = ENV("CHATWOOT_INBOX_ID");
const PUBLIC_URL = ENV("BRIDGE_PUBLIC_URL").replace(/\/$/, "");
const VERIFY_SIG = ENV("ZALO_VERIFY_SIGNATURE", "true") !== "false";

const STATE_FILE = join(DATA_DIR, "state.json");
let state = { tokens: null, users: {}, convToUid: {} };
try { state = { ...state, ...JSON.parse(readFileSync(STATE_FILE, "utf8")) }; } catch { /* fresh */ }
function saveState() {
  try { mkdirSync(DATA_DIR, { recursive: true }); writeFileSync(STATE_FILE, JSON.stringify(state)); }
  catch (e) { log("state.save.fail", { error: String(e) }); }
}
function log(event, extra = {}) {
  console.log(JSON.stringify({ ts: new Date().toISOString(), event, ...extra }));
}

// ---------- Zalo OAuth v4 (refresh token xoay vòng, phải lưu lại) ----------
async function exchangeToken(params) {
  const body = new URLSearchParams({ app_id: APP_ID, ...params });
  const res = await fetch("https://oauth.zaloapp.com/v4/oa/access_token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", secret_key: APP_SECRET },
    body,
  });
  const data = await res.json();
  if (!data.access_token) throw new Error("zalo oauth failed: " + JSON.stringify(data));
  state.tokens = {
    access: data.access_token,
    refresh: data.refresh_token,
    expiresAt: Date.now() + (Number(data.expires_in || 3600) - 300) * 1000,
  };
  saveState();
  return state.tokens;
}
async function zaloAccessToken() {
  if (!state.tokens) throw new Error("CHUA_UY_QUYEN: mở " + PUBLIC_URL + "/oauth/start để uỷ quyền OA");
  if (Date.now() < state.tokens.expiresAt) return state.tokens.access;
  await exchangeToken({ grant_type: "refresh_token", refresh_token: state.tokens.refresh });
  return state.tokens.access;
}

// ---------- Chatwoot Application API ----------
async function cw(method, path, body) {
  const res = await fetch(`${CW_URL}/api/v1/accounts/${CW_ACCOUNT}${path}`, {
    method,
    headers: { "Content-Type": "application/json", api_access_token: CW_TOKEN },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`chatwoot ${method} ${path} -> ${res.status} ${await res.text()}`);
  return res.json();
}
// Bền qua restart: tìm theo identifier trước, cache sau.
async function ensureContact(uid, profile) {
  const cached = state.users[uid];
  if (cached?.contactId) return cached.contactId;
  const identifier = `zalo:${uid}`;
  let contactId = null;
  try {
    const found = await cw("GET", `/contacts/search?q=${encodeURIComponent(identifier)}`);
    contactId = found?.payload?.find((c) => c.identifier === identifier)?.id ?? null;
  } catch { /* search có thể rỗng */ }
  if (!contactId) {
    const created = await cw("POST", "/contacts", {
      inbox_id: Number(CW_INBOX),
      name: profile?.display_name || `Khách Zalo ${uid.slice(-6)}`,
      identifier,
      custom_attributes: { zalo_user_id: uid, kenh: "zalo_oa" },
    });
    contactId = created?.payload?.contact?.id ?? created?.payload?.id ?? created?.id;
  }
  state.users[uid] = { ...(state.users[uid] || {}), contactId };
  saveState();
  return contactId;
}
async function ensureConversation(uid, contactId) {
  const cached = state.users[uid];
  if (cached?.conversationId) return cached.conversationId;
  let convId = null;
  try {
    const list = await cw("GET", `/contacts/${contactId}/conversations`);
    convId = (list?.payload || []).find(
      (c) => String(c.inbox_id) === String(CW_INBOX) && c.status !== "resolved",
    )?.id ?? null;
  } catch { /* no conversations yet */ }
  if (!convId) {
    const conv = await cw("POST", "/conversations", {
      inbox_id: Number(CW_INBOX),
      contact_id: contactId,
      source_id: `zalo:${uid}`,
      status: "open",
    });
    convId = conv?.id;
  }
  state.users[uid].conversationId = convId;
  state.convToUid[String(convId)] = uid;
  saveState();
  return convId;
}
async function pushIncoming(uid, text, profile) {
  const contactId = await ensureContact(uid, profile);
  const convId = await ensureConversation(uid, contactId);
  await cw("POST", `/conversations/${convId}/messages`, {
    content: text, message_type: "incoming", private: false,
  });
  log("zalo.incoming.delivered", { uid, convId });
}

// ---------- Zalo webhook ----------
function verifyZaloSignature(rawBody, headers) {
  if (!VERIFY_SIG) return true;
  const sig = (headers["x-zevent-signature"] || "").replace(/^mac=/, "");
  if (!sig) return false;
  let ts = "";
  try { ts = String(JSON.parse(rawBody).timestamp ?? ""); } catch { return false; }
  const mac = createHash("sha256").update(APP_ID + rawBody + ts + APP_SECRET).digest("hex");
  return mac === sig;
}
function extractZaloText(ev) {
  const m = ev?.message;
  if (typeof m?.text === "string" && m.text) return m.text;
  const att = m?.attachments?.[0];
  if (att?.type) return `[${att.type}] ` + (att?.payload?.url || att?.payload?.thumbnail || "(đính kèm)");
  return null;
}
async function handleZaloEvent(ev) {
  const name = ev?.event_name || "";
  if (!name.startsWith("user_send")) { log("zalo.event.skip", { name }); return; }
  const uid = ev?.sender?.id;
  if (!uid) return;
  const text = extractZaloText(ev) ?? `(sự kiện ${name})`;
  await pushIncoming(uid, text, ev?.sender);
}

// ---------- Chatwoot webhook (agent trả lời -> gửi ra Zalo) ----------
async function handleChatwootEvent(payload) {
  if (payload?.event !== "message_created") return;
  if (payload?.message_type !== "outgoing" || payload?.private) return;
  const convId = String(payload?.conversation?.id ?? "");
  let uid = state.convToUid[convId];
  if (!uid) {
    const srcId = payload?.conversation?.contact_inbox?.source_id || "";
    if (srcId.startsWith("zalo:")) uid = srcId.slice(5);
  }
  if (!uid) { log("cw.outgoing.no_uid", { convId }); return; }
  const token = await zaloAccessToken();
  const res = await fetch("https://openapi.zalo.me/v3.0/oa/message/cs", {
    method: "POST",
    headers: { "Content-Type": "application/json", access_token: token },
    body: JSON.stringify({ recipient: { user_id: uid }, message: { text: payload?.content ?? "" } }),
  });
  const data = await res.json();
  if (data?.error && data.error !== 0) log("zalo.send.fail", { convId, uid, data });
  else log("zalo.send.ok", { convId, uid });
}

// ---------- HTTP server ----------
function readBody(req) {
  return new Promise((resolve) => {
    let b = ""; req.on("data", (c) => (b += c)); req.on("end", () => resolve(b));
  });
}
const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  const send = (code, body, type = "application/json") => {
    res.writeHead(code, { "Content-Type": type + "; charset=utf-8" }); res.end(body);
  };
  try {
    if (url.pathname === "/healthz") {
      return send(200, JSON.stringify({ status: "ok", oa_uy_quyen: Boolean(state.tokens) }));
    }
    if (url.pathname === "/oauth/start") {
      const target = `https://oauth.zaloapp.com/v4/oa/permission?app_id=${APP_ID}&redirect_uri=${encodeURIComponent(PUBLIC_URL + "/oauth/callback")}&state=llacrm`;
      res.writeHead(302, { Location: target }); return res.end();
    }
    if (url.pathname === "/oauth/callback") {
      const code = url.searchParams.get("code");
      if (!code) return send(400, "Thiếu code", "text/plain");
      await exchangeToken({ grant_type: "authorization_code", code });
      log("oauth.ok", {});
      return send(200, "<h2>✅ Đã uỷ quyền Zalo OA cho LLA CRM. Bạn có thể đóng tab này.</h2>", "text/html");
    }
    if (url.pathname === "/webhook/zalo" && req.method === "POST") {
      const raw = await readBody(req);
      // Zalo BẮT BUỘC webhook trả 200 OK cho cả lần "Kiểm tra" lẫn mọi sự kiện,
      // nếu trả mã khác 200 Zalo sẽ coi webhook không hợp lệ. Vì vậy luôn ACK 200,
      // rồi mới xác minh chữ ký và CHỈ xử lý sự kiện hợp lệ.
      send(200, JSON.stringify({ ok: true }));
      let valid = false;
      try { valid = verifyZaloSignature(raw, req.headers); } catch { valid = false; }
      if (!valid) { log("zalo.sig.skip", { reason: "invalid_or_missing_signature" }); return; }
      handleZaloEvent(JSON.parse(raw)).catch((e) => log("zalo.handle.fail", { error: String(e) }));
      return;
    }
    if (url.pathname === "/webhook/zalo" && req.method === "GET") {
      // Một số cấu hình Zalo gọi GET để kiểm tra tồn tại endpoint.
      return send(200, JSON.stringify({ ok: true }));
    }
    if (url.pathname === "/webhook/chatwoot" && req.method === "POST") {
      const raw = await readBody(req);
      send(200, JSON.stringify({ ok: true }));
      handleChatwootEvent(JSON.parse(raw)).catch((e) => log("cw.handle.fail", { error: String(e) }));
      return;
    }
    if (url.pathname === "/") {
      return send(200, `<h2>LLA CRM · Zalo OA Bridge</h2><p>OA uỷ quyền: ${state.tokens ? "✅ rồi" : "❌ chưa — <a href='/oauth/start'>bấm để uỷ quyền</a>"}</p>`, "text/html");
    }
    send(404, "not found", "text/plain");
  } catch (e) {
    log("http.error", { path: url.pathname, error: String(e) });
    send(500, "internal error", "text/plain");
  }
});
if (ENV("NODE_ENV") !== "test") {
  server.listen(PORT, "0.0.0.0", () => log("bridge.started", { port: PORT }));
}
export { verifyZaloSignature, extractZaloText, handleChatwootEvent, handleZaloEvent, state };
