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
//               CHATWOOT_ACCOUNT_ID, CHATWOOT_INBOX_ID, BRIDGE_PUBLIC_URL,
//               CHATWOOT_WEBHOOK_SECRET (= `secret` của inbox API trong LLA CRM)
// ENV tuỳ chọn: PORT (8787), DATA_DIR (/data), ZALO_VERIFY_SIGNATURE (true),
//               ZALO_HTTP_PROXY

import { createServer } from "node:http";
import { createHash, createHmac, timingSafeEqual } from "node:crypto";
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
const CW_SECRET = ENV("CHATWOOT_WEBHOOK_SECRET");
const VERIFY_CW_SIG = ENV("CHATWOOT_VERIFY_SIGNATURE", "true") !== "false";
// Cửa sổ chấp nhận lệch giờ của webhook LLA CRM. Chữ ký ký cả timestamp, nên
// giới hạn này là thứ duy nhất ngăn phát lại một yêu cầu đã bắt được.
const CW_SIG_MAX_SKEW_MS = 5 * 60 * 1000;
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
async function resolveRecentUser(matchText, uid) {
  try {
    const q = encodeURIComponent(JSON.stringify({ offset: 0, count: 10 }));
    const data = await zaloApi("/v2.0/oa/listrecentchat?data=" + q);
    const list = Array.isArray(data?.data) ? data.data : [];
    const OA_ID = ENV("ZALO_OA_ID");
    const hit =
      list.find((m) => String(m.from_id) === String(uid)) ||
      (matchText && list.find((m) => (m.message || "") === matchText && m.src === 1)) ||
      null;
    if (hit && (!OA_ID || String(hit.from_id) !== OA_ID))
      return { userId: hit.from_id, name: hit.from_display_name, avatar: hit.from_avatar };
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
// So sánh hai chuỗi hex trong thời gian không phụ thuộc nội dung. `===` trả lời
// sớm ngay ký tự đầu khác nhau, đủ để dò dần từng byte của một chữ ký hợp lệ.
function safeEqualHex(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  const bufA = Buffer.from(a, "utf8");
  const bufB = Buffer.from(b, "utf8");
  return bufA.length === bufB.length && timingSafeEqual(bufA, bufB);
}
function verifyZaloSignature(rawBody, headers) {
  if (!VERIFY_SIG) return true;
  const sig = (headers["x-zevent-signature"] || "").replace(/^mac=/, "");
  if (!sig) return false;
  let ts = "";
  try { ts = String(JSON.parse(rawBody).timestamp ?? ""); } catch { return false; }
  const mac = createHash("sha256").update(APP_ID + rawBody + ts + APP_SECRET).digest("hex");
  return safeEqualHex(mac, sig);
}

// LLA CRM ký mọi webhook của inbox API bằng `secret` của inbox đó:
//   X-Chatwoot-Signature: sha256=HMAC_SHA256(secret, "<timestamp>.<body>")
// Không kiểm tra chữ ký thì /webhook/chatwoot là một cửa gửi tin mở: bất kỳ ai
// đoán được id hội thoại đều nhắn được cho khách qua OA của tenant.
function verifyChatwootSignature(rawBody, headers, now = Date.now()) {
  if (!VERIFY_CW_SIG) return { ok: true };
  if (!CW_SECRET) return { ok: false, reason: "missing_secret_config" };
  const sig = String(headers["x-chatwoot-signature"] || "").replace(/^sha256=/, "");
  const ts = String(headers["x-chatwoot-timestamp"] || "");
  if (!sig || !ts) return { ok: false, reason: "missing_signature" };
  const skew = Math.abs(now - Number(ts) * 1000);
  if (!Number.isFinite(skew) || skew > CW_SIG_MAX_SKEW_MS) return { ok: false, reason: "stale_timestamp" };
  const mac = createHmac("sha256", CW_SECRET).update(`${ts}.${rawBody}`).digest("hex");
  return safeEqualHex(mac, sig) ? { ok: true } : { ok: false, reason: "bad_signature" };
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
  const OA_ID = ENV("ZALO_OA_ID");
  const evOa = String(ev?.oa_id || ev?.recipient?.id || "");
  if (OA_ID && evOa && evOa !== OA_ID) { log("zalo.event.foreign_oa", { name, oa: evOa }); return; }
  if (!name.startsWith("user_send")) { log("zalo.event.skip", { name }); return; }
  const uid = ev?.sender?.id;
  if (!uid) return;
  const msgId = ev?.message?.msg_id;
  if (msgId) {
    state.seenMsgs = Array.isArray(state.seenMsgs) ? state.seenMsgs : [];
    if (state.seenMsgs.includes(msgId)) { log("zalo.event.dup", { msgId }); return; }
    state.seenMsgs.push(msgId);
    if (state.seenMsgs.length > 500) state.seenMsgs = state.seenMsgs.slice(-250);
    saveState();
  }
  const text = extractZaloText(ev) ?? `(sự kiện ${name})`;
  const matchText = typeof ev?.message?.text === "string" ? ev.message.text : null;
  const resolved = await resolveRecentUser(matchText, uid);
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

// ---------- v2: multi-connection (SaaS self-service onboarding) ----------
const ADMIN_TOKEN = ENV("BRIDGE_ADMIN_TOKEN");
function connOf(id) { return (state.connections || {})[id] || null; }
function saveConn(id, patch) {
  state.connections = state.connections || {};
  state.connections[id] = { ...(state.connections[id] || {}), ...patch };
  saveState();
  return state.connections[id];
}
function randToken(n = 24) {
  const abc = "abcdefghijklmnopqrstuvwxyz0123456789";
  let r = ""; for (let i = 0; i < n; i++) r += abc[Math.floor(Math.random() * abc.length)];
  return r;
}
async function connZaloFetch(conn, path, { method = "GET", body, headers = {} } = {}) {
  const doFetch = (useProxy) => fetch("https://openapi.zalo.me" + path, {
    method,
    headers: { "Content-Type": "application/json", access_token: conn.tokens?.access || "", ...headers },
    body: body === undefined ? undefined : JSON.stringify(body),
    ...(useProxy && zaloDispatcher ? { dispatcher: zaloDispatcher } : {}),
  }).then((r) => r.json());
  let mode = conn.egress || "auto";
  if (mode === "proxy") return doFetch(true);
  const direct = await doFetch(false).catch(() => null);
  if (direct && direct.error === -501 && zaloDispatcher) {
    saveConn(conn.id, { egress: "proxy" });
    log("conn.egress.switch", { conn: conn.id, to: "proxy" });
    return doFetch(true);
  }
  if (mode === "auto" && direct && direct.error !== -501) saveConn(conn.id, { egress: "direct" });
  return direct;
}
async function connExchangeToken(conn, params) {
  const doPost = (useProxy) => fetch("https://oauth.zaloapp.com/v4/oa/access_token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded", secret_key: conn.appSecret },
    body: new URLSearchParams({ app_id: conn.appId, ...params }).toString(),
    ...(useProxy && zaloDispatcher ? { dispatcher: zaloDispatcher } : {}),
  }).then((r) => r.json());
  let data = await doPost(conn.egress === "proxy").catch(() => null);
  if ((!data || data.error) && zaloDispatcher && conn.egress !== "proxy") {
    data = await doPost(true);
    if (data && !data.error) saveConn(conn.id, { egress: "proxy" });
  }
  if (!data || data.error || !data.access_token) throw new Error("oauth_exchange_failed " + JSON.stringify(data || {}));
  saveConn(conn.id, { tokens: { access: data.access_token, refresh: data.refresh_token, expiresAt: Date.now() + (Number(data.expires_in || 3600) - 300) * 1000 } });
  return true;
}
function connPublicView(conn) {
  return {
    id: conn.id, name: conn.name, app_id: conn.appId,
    webhook_url: `${PUBLIC_URL}/webhook/zalo/c/${conn.id}/${conn.webhookToken}`,
    oauth_callback_url: `${PUBLIC_URL}/oauth/callback`,
    oauth_url: `${PUBLIC_URL}/oauth/start?conn=${conn.id}`,
    status: {
      authorized: Boolean(conn.tokens?.access),
      webhook_received: Boolean(conn.lastEventAt),
      last_event_at: conn.lastEventAt || null,
      egress: conn.egress || "auto",
      oa: conn.oa || null,
    },
  };
}
async function handleConnApi(req, url, send, readBodyFn) {
  if (!ADMIN_TOKEN) return send(503, JSON.stringify({ error: "admin_token_not_configured" }));
  if ((req.headers["x-bridge-admin-token"] || "") !== ADMIN_TOKEN) return send(401, JSON.stringify({ error: "unauthorized" }));
  if (url.pathname === "/api/connections" && req.method === "POST") {
    const b = JSON.parse((await readBodyFn(req)) || "{}");
    const appId = String(b.app_id || "").trim();
    const appSecret = String(b.app_secret || "").trim();
    if (!/^[0-9]{5,25}$/.test(appId) || appSecret.length < 8) return send(422, JSON.stringify({ error: "invalid_app_credentials" }));
    const id = randToken(10);
    const conn = saveConn(id, { id, name: String(b.name || "Zalo OA").slice(0, 80), appId, appSecret, webhookToken: randToken(28), egress: "auto", createdAt: Date.now() });
    log("conn.created", { conn: id, app: appId });
    return send(201, JSON.stringify(connPublicView(conn)));
  }
  const m = url.pathname.match(/^\/api\/connections\/([a-z0-9]+)$/);
  if (m && req.method === "GET") {
    const conn = connOf(m[1]);
    if (!conn) return send(404, JSON.stringify({ error: "not_found" }));
    if (conn.tokens?.access && !conn.oa) {
      const info = await connZaloFetch(conn, "/v2.0/oa/getoa").catch(() => null);
      if (info && info.error === 0 && info.data) saveConn(conn.id, { oa: { id: String(info.data.oa_id || ""), name: info.data.name || "" } });
    }
    return send(200, JSON.stringify(connPublicView(connOf(m[1]))));
  }
  return send(404, JSON.stringify({ error: "unknown_api" }));
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
      return send(200, JSON.stringify({
        status: "ok",
        oa_uy_quyen: Boolean(state.tokens),
        proxy: Boolean(zaloDispatcher),
        chu_ky_zalo: VERIFY_SIG,
        chu_ky_crm: VERIFY_CW_SIG && Boolean(CW_SECRET),
      }));
    }
    if (url.pathname === "/oauth/start") {
      const cid = url.searchParams.get("conn");
      const appId = cid && connOf(cid) ? connOf(cid).appId : APP_ID;
      const st = cid ? `conn:${cid}` : "llacrm";
      const target = `https://oauth.zaloapp.com/v4/oa/permission?app_id=${appId}&redirect_uri=${encodeURIComponent(PUBLIC_URL + "/oauth/callback")}&state=${encodeURIComponent(st)}`;
      res.writeHead(302, { Location: target }); return res.end();
    }
    if (url.pathname === "/oauth/callback") {
      const code = url.searchParams.get("code");
      if (!code) return send(400, "Thiếu code", "text/plain");
      const st = url.searchParams.get("state") || "";
      if (st.startsWith("conn:")) {
        const conn = connOf(st.slice(5));
        if (!conn) return send(404, "Connection không tồn tại", "text/plain");
        await connExchangeToken(conn, { grant_type: "authorization_code", code });
        log("conn.oauth.ok", { conn: conn.id });
        return send(200, "<h2>✅ Đã uỷ quyền OA cho kết nối riêng. Quay lại phần mềm để tiếp tục.</h2>", "text/html");
      }
      await exchangeToken({ grant_type: "authorization_code", code });
      log("oauth.ok", {});
      return send(200, "<h2>✅ Đã uỷ quyền Zalo OA cho LLA CRM. Bạn có thể đóng tab này.</h2>", "text/html");
    }
    if (url.pathname.startsWith("/api/connections")) {
      return await handleConnApi(req, url, send, readBody);
    }
    if (url.pathname.startsWith("/webhook/zalo/c/") && req.method === "POST") {
      const raw = await readBody(req);
      send(200, JSON.stringify({ ok: true }));
      const mm = url.pathname.match(/^\/webhook\/zalo\/c\/([a-z0-9]+)\/([a-z0-9]+)$/);
      const conn = mm && connOf(mm[1]);
      if (!conn || conn.webhookToken !== mm[2]) { log("conn.webhook.bad", {}); return; }
      saveConn(conn.id, { lastEventAt: Date.now() });
      log("conn.webhook.received", { conn: conn.id, name: (JSON.parse(raw || "{}").event_name) || "" });
      return;
    }
    if (url.pathname.startsWith("/webhook/zalo") && req.method === "POST") {
      const raw = await readBody(req);
      // Zalo BẮT BUỘC 200 OK cho cả lần Kiểm tra lẫn mọi sự kiện; luôn ACK 200.
      send(200, JSON.stringify({ ok: true }));
      // Bảo mật chống giả mạo: nếu đặt ZALO_WEBHOOK_TOKEN thì webhook URL phải là
      // /webhook/zalo/<token>. Zalo cho đặt URL tuỳ ý nên đây là xác thực đáng tin,
      // không phụ thuộc công thức chữ ký (mac) của Zalo.
      const WEBHOOK_TOKEN = ENV("ZALO_WEBHOOK_TOKEN");
      if (WEBHOOK_TOKEN) {
        const suffix = url.pathname.replace(/^\/webhook\/zalo\/?/, "");
        if (suffix !== WEBHOOK_TOKEN) { log("zalo.webhook.bad_token", {}); return; }
      }
      let valid = false;
      try { valid = verifyZaloSignature(raw, req.headers); } catch { valid = false; }
      if (!valid && VERIFY_SIG) { log("zalo.sig.skip", { reason: "invalid_or_missing_signature" }); return; }
      handleZaloEvent(JSON.parse(raw)).catch((e) => log("zalo.handle.fail", { error: String(e) }));
      return;
    }
    if (url.pathname.startsWith("/webhook/zalo") && req.method === "GET") {
      return send(200, JSON.stringify({ ok: true }));
    }
    if (url.pathname === "/webhook/chatwoot" && req.method === "POST") {
      const raw = await readBody(req);
      const verdict = verifyChatwootSignature(raw, req.headers);
      if (!verdict.ok) {
        log("cw.sig.reject", { reason: verdict.reason });
        return send(401, JSON.stringify({ ok: false, error: verdict.reason }));
      }
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
  // Thiếu secret thì mọi webhook của CRM sẽ bị từ chối 401 — nói ra ngay lúc khởi
  // động thay vì để người vận hành đi tìm lý do agent trả lời mà khách không nhận được.
  if (VERIFY_CW_SIG && !CW_SECRET) {
    log("bridge.config.missing", {
      error: "CHATWOOT_WEBHOOK_SECRET chưa đặt — /webhook/chatwoot sẽ trả 401. " +
        "Lấy `secret` của inbox API trong LLA CRM rồi đặt vào biến môi trường này.",
    });
  }
  server.listen(PORT, "0.0.0.0", () => log("bridge.started", {
    port: PORT, proxy: Boolean(zaloDispatcher), chu_ky_crm: VERIFY_CW_SIG && Boolean(CW_SECRET),
  }));
}
export { verifyZaloSignature, verifyChatwootSignature, extractZaloText, handleChatwootEvent, handleZaloEvent, state };
