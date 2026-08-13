// LLA CRM — Zalo OA Bridge
// Cầu nối Zalo Official Account ↔ LLA CRM (Chatwoot API channel inbox).
// Node.js >= 20. Phụ thuộc: undici (chỉ dùng khi bật proxy). MIT — © 2026 LLA.
//
// Luồng vào:  Zalo webhook -> /webhook/zalo -> resolve user_id thật + tên -> ghi tin incoming
// Luồng ra:   LLA CRM inbox webhook -> /webhook/chatwoot -> gửi tin ra Zalo CS API
// OAuth:      /oauth/start -> Zalo permission -> /oauth/callback -> lưu token (refresh xoay vòng)
//
// Zalo YÊU CẦU các lệnh gọi API từ IP Việt Nam. Đặt ZALO_HTTP_PROXY=http://host:port
// để định tuyến riêng openapi.zalo.me / oauth.zaloapp.com qua proxy VN.
//
// ENV bắt buộc: ZALO_APP_ID, ZALO_APP_SECRET, CHATWOOT_URL, CHATWOOT_API_TOKEN,
//               CHATWOOT_ACCOUNT_ID, CHATWOOT_INBOX_ID, BRIDGE_PUBLIC_URL
// ENV tuỳ chọn: PORT (8787), DATA_DIR (/data), ZALO_VERIFY_SIGNATURE (true),
//               ZALO_HTTP_PROXY

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
const ZALO_PROXY = ENV("ZALO_HTTP_PROXY");

// Khi ZALO_HTTP_PROXY được đặt, các fetch tới Zalo đi qua proxy VN đó.
let zaloDispatcher;
if (ZALO_PROXY && ENV("NODE_ENV") !== "test") {
  const { ProxyAgent } = await import("undici");
  zaloDispatcher = new ProxyAgent(ZALO_PROXY);
}
function zfetch(url, opts = {}) {
  return fetch(url, zaloDispatcher ? { ...opts, dispatcher: zaloDispatcher } : opts);
}

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
  const res = await zfetch("https://oauth.zaloapp.com/v4/oa/access_token", {
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

// ---------- Zalo Open API (qua proxy VN) ----------
async function zaloApi(path, { method = "GET", body } = {}) {
  const token = await zaloAccessToken();
  const res = await zfetch("https://openapi.zalo.me" + path, {
    method,
    headers: { access_token: token, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return res.json();
}

// Webhook chỉ cho `user_id_by_app`, nhưng CS API cần `user_id` thật.
// listrecentchat trả cả user_id (from_id), tên và avatar — dùng để resolve.
async function resolveRecentUser(matchText) {
  try {
    const q = encodeURIComponent(JSON.stringify({ offset: 0, count: 10 }));
    const data = await zaloApi("/v2.0/oa/listrecentchat?data=" + q);
    const list = Array.isArray(data?.data) ? data.data : [];
    const hit =
      (matchText && list.find((m) => (m.message || "") === matchText && m.src === 1)) ||
      list.find((m) => m.src === 1) ||
      list[0];
    if (hit) return { userId: hit.from_id, name: hit.from_display_name, avatar: hit.from_avatar };
  } catch (e) {
    log("zalo.resolve.fail", { error: String(e) });
  }
  return null;
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
async function ensureContact(uid, profile) {
  const cached = state.users[uid];
  if (cached?.contactId) {
    // Cập nhật tên/avatar thật nếu trước đó chỉ là placeholder "Khách Zalo".
    if (profile?.display_name && !cached.named) {
      try {
        await cw("PUT", `/contacts/${cached.contactId}`, {
          name: profile.display_name,
          avatar_url: profile.avatar || undefined,
        });
        state.users[uid].named = true;
        saveState();
      } catch { /* bỏ qua lỗi cập nhật tên */ }
    }
    return cached.contactId;
  }
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
      avatar_url: profile?.avatar || undefined,
      custom_attributes: { zalo_user_id: uid, kenh: "zalo_oa" },
    });
    contactId = created?.payload?.contact?.id ?? created?.payload?.id ?? created?.id;
  }
  state.users[uid] = { ...(state.users[uid] || {}), contactId, named: Boolean(profile?.display_name) };
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
  if (profile?.sendUserId) {
    state.users[uid].sendUserId = profile.sendUserId;
    saveState();
  }
  await cw("POST", `/conversations/${convId}/messages`, {
    content: text, message_type: "incoming", private: false,
  });
  log("zalo.incoming.delivered", { uid, convId, resolved: Boolean(profile?.sendUserId) });
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
  const matchText = typeof ev?.message?.text === "string" ? ev.message.text : null;
  const resolved = await resolveRecentUser(matchText);
  await pushIncoming(uid, text, {
    display_name: resolved?.name,
    avatar: resolved?.avatar,
    sendUserId: resolved?.userId,
  });
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
  // Gửi tới user_id THẬT (đã resolve khi nhận tin); fallback về uid nếu chưa có.
  const sendId = state.users[uid]?.sendUserId || uid;
  const data = await zaloApi("/v3.0/oa/message/cs", {
    method: "POST",
    body: { recipient: { user_id: sendId }, message: { text: payload?.content ?? "" } },
  });
  if (data?.error && data.error !== 0) log("zalo.send.fail", { convId, sendId, data });
  else log("zalo.send.ok", { convId, sendId });
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
      return send(200, JSON.stringify({ status: "ok", oa_uy_quyen: Boolean(state.tokens), proxy: Boolean(zaloDispatcher) }));
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
      // Zalo BẮT BUỘC 200 OK cho cả lần Kiểm tra lẫn mọi sự kiện; luôn ACK 200,
      // rồi mới xác minh chữ ký và CHỈ xử lý sự kiện hợp lệ.
      send(200, JSON.stringify({ ok: true }));
      // Debug chữ ký: log không điều kiện để dò đúng công thức Zalo (bật bằng ZALO_SIG_DEBUG=1).
      if (ENV("ZALO_SIG_DEBUG") === "1") {
        try {
          const hdrs = Object.keys(req.headers).filter((h) => /sig|mac|zevent|zalo/i.test(h));
          let ts = ""; try { ts = String(JSON.parse(raw).timestamp ?? ""); } catch { /* */ }
          const c1 = createHash("sha256").update(APP_ID + raw + ts + APP_SECRET).digest("hex");
          const c2 = createHash("sha256").update(raw + APP_SECRET).digest("hex");
          const c3 = createHash("sha256").update(APP_ID + ts + APP_SECRET).digest("hex");
          log("zalo.sig.debug", {
            sigHeaders: hdrs.map((h) => h + "=" + String(req.headers[h]).slice(0, 30)),
            ts, bodyLen: raw.length,
            c_appid_body_ts: c1.slice(0, 16), c_body: c2.slice(0, 16), c_appid_ts: c3.slice(0, 16),
          });
        } catch { /* */ }
      }
      let valid = false;
      try { valid = verifyZaloSignature(raw, req.headers); } catch { valid = false; }
      if (!valid && VERIFY_SIG) { log("zalo.sig.skip", { reason: "invalid_or_missing_signature" }); return; }
      handleZaloEvent(JSON.parse(raw)).catch((e) => log("zalo.handle.fail", { error: String(e) }));
      return;
    }
    if (url.pathname === "/webhook/zalo" && req.method === "GET") {
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
  server.listen(PORT, "0.0.0.0", () => log("bridge.started", { port: PORT, proxy: Boolean(zaloDispatcher) }));
}
export { verifyZaloSignature, extractZaloText, handleChatwootEvent, handleZaloEvent, state };
