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
// Địa chỉ Zalo tách ra biến để bộ kiểm thử dựng được một Zalo giả — nếu không thì
// mọi kiểm thử luồng tin đều phải gọi ra Internet, và ở CI thì chúng chỉ chứng minh
// được rằng mạng bị chặn.
const ZALO_API_BASE = ENV("ZALO_API_BASE", "https://openapi.zalo.me").replace(/\/$/, "");
const ZALO_OAUTH_BASE = ENV("ZALO_OAUTH_BASE", "https://oauth.zaloapp.com").replace(/\/$/, "");

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
  const res = await zfetch(ZALO_OAUTH_BASE + "/v4/oa/access_token", {
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
  const res = await zfetch(ZALO_API_BASE + path, {
    method,
    headers: { access_token: token, ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  return res.json();
}

// Một đường gọi Zalo cho cả hai loại kết nối. Kết nối legacy dùng token trong
// `state.tokens`; kết nối riêng dùng token của chính nó và tự làm mới khi hết hạn —
// thiếu bước làm mới thì kết nối sống đúng một giờ rồi im lặng chết.
async function zaloCall(conn, path, opts = {}) {
  if (!conn || conn.legacy) return zaloApi(path, opts);
  const tk = conn.tokens;
  if (!tk?.access) throw new Error("CHUA_UY_QUYEN: kết nối " + conn.id + " chưa uỷ quyền OA");
  if (tk.expiresAt && Date.now() >= tk.expiresAt) {
    if (!tk.refresh) throw new Error("CHUA_UY_QUYEN: token hết hạn và không có refresh token");
    await connExchangeToken(conn, { grant_type: "refresh_token", refresh_token: tk.refresh });
    conn = connOf(conn.id) || conn;
  }
  return connZaloFetch(conn, path, opts);
}

// Webhook chỉ cho `user_id_by_app`, nhưng CS API cần `user_id` thật.
// listrecentchat trả cả user_id (from_id), tên và avatar — dùng để resolve.
async function resolveRecentUser(conn, matchText, uid) {
  try {
    const q = encodeURIComponent(JSON.stringify({ offset: 0, count: 10 }));
    const data = await zaloCall(conn, "/v2.0/oa/listrecentchat?data=" + q);
    const list = Array.isArray(data?.data) ? data.data : [];
    const OA_ID = conn.oaId || conn.oa?.id || "";
    const hit =
      list.find((m) => String(m.from_id) === String(uid)) ||
      (matchText && list.find((m) => (m.message || "") === matchText && m.src === 1)) ||
      null;
    if (hit && (!OA_ID || String(hit.from_id) !== OA_ID))
      return { userId: hit.from_id, name: hit.from_display_name, avatar: hit.from_avatar };
  } catch (e) {
    log("zalo.resolve.fail", { conn: conn.id, error: String(e) });
  }
  return null;
}

// ---------- Kết nối: đơn vị công việc ----------
// Cầu phục vụ nhiều OA. Kết nối cấu hình bằng biến môi trường (OA đầu tiên của LLA)
// được gói thành một "kết nối legacy" để chỉ có MỘT đường code cho mọi OA — và để
// dữ liệu ánh xạ liên hệ/hội thoại đang chạy thật của nó không phải di trú đi đâu.
function legacyConn() {
  return {
    id: "default", legacy: true, name: "OA cấu hình bằng ENV",
    appId: APP_ID, appSecret: APP_SECRET, oaId: ENV("ZALO_OA_ID"),
    cwAccountId: CW_ACCOUNT, cwInboxId: CW_INBOX, cwWebhookSecret: CW_SECRET,
  };
}
// Hộp lưu ánh xạ của một kết nối: users, convToUid, seenMsgs.
// Legacy dùng thẳng gốc `state` (dữ liệu thật đã nằm đó); kết nối mới dùng ô riêng.
function boxOf(conn) {
  const box = conn.legacy ? state : (state.connections?.[conn.id] || {});
  box.users ||= {};
  box.convToUid ||= {};
  box.seenMsgs ||= [];
  return box;
}
function cwTargetOf(conn) {
  return {
    account: conn.cwAccountId || CW_ACCOUNT,
    inbox: conn.cwInboxId || CW_INBOX,
    token: conn.cwToken || CW_TOKEN,
    secret: conn.legacy ? CW_SECRET : (conn.cwWebhookSecret || ""),
  };
}

// ---------- Chatwoot Application API ----------
async function cw(conn, method, path, body) {
  const t = cwTargetOf(conn);
  const res = await fetch(`${CW_URL}/api/v1/accounts/${t.account}${path}`, {
    method,
    headers: { "Content-Type": "application/json", api_access_token: t.token },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  if (!res.ok) throw new Error(`chatwoot ${method} ${path} -> ${res.status} ${await res.text()}`);
  return res.json();
}
async function ensureContact(conn, uid, profile) {
  const box = boxOf(conn);
  const inboxId = Number(cwTargetOf(conn).inbox);
  const cached = box.users[uid];
  if (cached?.contactId) {
    // Cập nhật tên/avatar thật nếu trước đó chỉ là placeholder "Khách Zalo".
    if (profile?.display_name && !cached.named) {
      try {
        await cw(conn, "PUT", `/contacts/${cached.contactId}`, {
          name: profile.display_name,
          avatar_url: profile.avatar || undefined,
        });
        box.users[uid].named = true;
        saveState();
      } catch { /* bỏ qua lỗi cập nhật tên */ }
    }
    return cached.contactId;
  }
  const identifier = `zalo:${uid}`;
  let contactId = null;
  try {
    const found = await cw(conn, "GET", `/contacts/search?q=${encodeURIComponent(identifier)}`);
    contactId = found?.payload?.find((c) => c.identifier === identifier)?.id ?? null;
  } catch { /* search có thể rỗng */ }
  if (!contactId) {
    const created = await cw(conn, "POST", "/contacts", {
      inbox_id: inboxId,
      name: profile?.display_name || `Khách Zalo ${uid.slice(-6)}`,
      identifier,
      avatar_url: profile?.avatar || undefined,
      custom_attributes: { zalo_user_id: uid, kenh: "zalo_oa" },
    });
    contactId = created?.payload?.contact?.id ?? created?.payload?.id ?? created?.id;
  }
  box.users[uid] = { ...(box.users[uid] || {}), contactId, named: Boolean(profile?.display_name) };
  saveState();
  return contactId;
}
async function ensureConversation(conn, uid, contactId) {
  const box = boxOf(conn);
  const inboxId = Number(cwTargetOf(conn).inbox);
  const cached = box.users[uid];
  if (cached?.conversationId) return cached.conversationId;
  let convId = null;
  try {
    const list = await cw(conn, "GET", `/contacts/${contactId}/conversations`);
    convId = (list?.payload || []).find(
      (c) => String(c.inbox_id) === String(inboxId) && c.status !== "resolved",
    )?.id ?? null;
  } catch { /* no conversations yet */ }
  if (!convId) {
    const conv = await cw(conn, "POST", "/conversations", {
      inbox_id: inboxId,
      contact_id: contactId,
      source_id: `zalo:${uid}`,
      status: "open",
    });
    convId = conv?.id;
  }
  box.users[uid].conversationId = convId;
  box.convToUid[String(convId)] = uid;
  saveState();
  return convId;
}
async function pushIncoming(conn, uid, text, profile) {
  const box = boxOf(conn);
  const contactId = await ensureContact(conn, uid, profile);
  const convId = await ensureConversation(conn, uid, contactId);
  if (profile?.sendUserId) {
    box.users[uid].sendUserId = profile.sendUserId;
    saveState();
  }
  await cw(conn, "POST", `/conversations/${convId}/messages`, {
    content: text, message_type: "incoming", private: false,
  });
  log("zalo.incoming.delivered", { conn: conn.id, uid, convId, resolved: Boolean(profile?.sendUserId) });
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
function verifyChatwootSignature(rawBody, headers, now = Date.now(), secret = CW_SECRET) {
  if (!VERIFY_CW_SIG) return { ok: true };
  if (!secret) return { ok: false, reason: "missing_secret_config" };
  const sig = String(headers["x-chatwoot-signature"] || "").replace(/^sha256=/, "");
  const ts = String(headers["x-chatwoot-timestamp"] || "");
  if (!sig || !ts) return { ok: false, reason: "missing_signature" };
  const skew = Math.abs(now - Number(ts) * 1000);
  if (!Number.isFinite(skew) || skew > CW_SIG_MAX_SKEW_MS) return { ok: false, reason: "stale_timestamp" };
  const mac = createHmac("sha256", secret).update(`${ts}.${rawBody}`).digest("hex");
  return safeEqualHex(mac, sig) ? { ok: true } : { ok: false, reason: "bad_signature" };
}
function extractZaloText(ev) {
  const m = ev?.message;
  if (typeof m?.text === "string" && m.text) return m.text;
  const att = m?.attachments?.[0];
  if (att?.type) return `[${att.type}] ` + (att?.payload?.url || att?.payload?.thumbnail || "(đính kèm)");
  return null;
}
async function handleZaloEvent(ev, conn = legacyConn()) {
  const name = ev?.event_name || "";
  const OA_ID = conn.oaId || conn.oa?.id || "";
  const evOa = String(ev?.oa_id || ev?.recipient?.id || "");
  if (OA_ID && evOa && evOa !== OA_ID) { log("zalo.event.foreign_oa", { conn: conn.id, name, oa: evOa }); return; }
  if (!name.startsWith("user_send")) { log("zalo.event.skip", { conn: conn.id, name }); return; }
  const uid = ev?.sender?.id;
  if (!uid) return;
  const box = boxOf(conn);
  const msgId = ev?.message?.msg_id;
  if (msgId) {
    if (box.seenMsgs.includes(msgId)) { log("zalo.event.dup", { conn: conn.id, msgId }); return; }
    box.seenMsgs.push(msgId);
    if (box.seenMsgs.length > 500) box.seenMsgs = box.seenMsgs.slice(-250);
    saveState();
  }
  // Kết nối chưa gắn hộp thư thì tin sẽ rơi vào hộp thư của ENV — im lặng gửi nhầm
  // tenant còn tệ hơn không gửi. Ghi nhận rồi dừng.
  if (!conn.legacy && !conn.cwInboxId) {
    log("conn.inbox.unbound", { conn: conn.id, name });
    return;
  }
  const text = extractZaloText(ev) ?? `(sự kiện ${name})`;
  const matchText = typeof ev?.message?.text === "string" ? ev.message.text : null;
  const resolved = await resolveRecentUser(conn, matchText, uid);
  await pushIncoming(conn, uid, text, {
    display_name: resolved?.name,
    avatar: resolved?.avatar,
    sendUserId: resolved?.userId,
  });
}

// ---------- Chatwoot webhook (agent trả lời -> gửi ra Zalo) ----------
async function handleChatwootEvent(payload, conn = legacyConn()) {
  if (payload?.event !== "message_created") return;
  if (payload?.message_type !== "outgoing" || payload?.private) return;
  const box = boxOf(conn);
  const convId = String(payload?.conversation?.id ?? "");
  let uid = box.convToUid[convId];
  if (!uid) {
    const srcId = payload?.conversation?.contact_inbox?.source_id || "";
    if (srcId.startsWith("zalo:")) uid = srcId.slice(5);
  }
  if (!uid) { log("cw.outgoing.no_uid", { conn: conn.id, convId }); return; }
  // Gửi tới user_id THẬT (đã resolve khi nhận tin); fallback về uid nếu chưa có.
  const sendId = box.users[uid]?.sendUserId || uid;
  const data = await zaloCall(conn, "/v3.0/oa/message/cs", {
    method: "POST",
    body: { recipient: { user_id: sendId }, message: { text: payload?.content ?? "" } },
  });
  if (data?.error && data.error !== 0) log("zalo.send.fail", { conn: conn.id, convId, sendId, data });
  else log("zalo.send.ok", { conn: conn.id, convId, sendId });
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
  const doFetch = (useProxy) => fetch(ZALO_API_BASE + path, {
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
  const doPost = (useProxy) => fetch(ZALO_OAUTH_BASE + "/v4/oa/access_token", {
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
    chatwoot_webhook_url: `${PUBLIC_URL}/webhook/chatwoot/c/${conn.id}`,
    inbox_id: conn.cwInboxId || null,
    account_id: conn.cwAccountId || null,
    status: {
      authorized: Boolean(conn.tokens?.access),
      webhook_received: Boolean(conn.lastEventAt),
      last_event_at: conn.lastEventAt || null,
      last_inbound_at: conn.lastInboundAt || null,
      last_outbound_at: conn.lastOutboundAt || null,
      inbox_linked: Boolean(conn.cwInboxId),
      outbound_secret_set: Boolean(conn.cwWebhookSecret),
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
    const conn = saveConn(id, {
      id, name: String(b.name || "Zalo OA").slice(0, 80), appId, appSecret,
      webhookToken: randToken(28), egress: "auto", createdAt: Date.now(),
      oaId: b.oa_id ? String(b.oa_id) : "",
      cwAccountId: b.cw_account_id ? String(b.cw_account_id) : "",
      cwInboxId: b.cw_inbox_id ? String(b.cw_inbox_id) : "",
      cwWebhookSecret: b.cw_webhook_secret ? String(b.cw_webhook_secret) : "",
      cwToken: b.cw_token ? String(b.cw_token) : "",
    });
    log("conn.created", { conn: id, app: appId });
    return send(201, JSON.stringify(connPublicView(conn)));
  }
  const m = url.pathname.match(/^\/api\/connections\/([a-z0-9]+)$/);
  // Hộp thư chỉ tồn tại sau khi CRM tạo xong inbox, nên việc gắn kết nối vào hộp thư
  // là một bước riêng sau khi tạo kết nối.
  if (m && req.method === "PATCH") {
    const conn = connOf(m[1]);
    if (!conn) return send(404, JSON.stringify({ error: "not_found" }));
    const b = JSON.parse((await readBodyFn(req)) || "{}");
    const patch = {};
    if (b.cw_account_id) patch.cwAccountId = String(b.cw_account_id);
    if (b.cw_inbox_id) patch.cwInboxId = String(b.cw_inbox_id);
    if (b.cw_webhook_secret) patch.cwWebhookSecret = String(b.cw_webhook_secret);
    if (b.cw_token) patch.cwToken = String(b.cw_token);
    if (b.oa_id) patch.oaId = String(b.oa_id);
    if (b.name) patch.name = String(b.name).slice(0, 80);
    if (!Object.keys(patch).length) return send(422, JSON.stringify({ error: "nothing_to_update" }));
    log("conn.bound", { conn: conn.id, inbox: patch.cwInboxId || conn.cwInboxId || null });
    return send(200, JSON.stringify(connPublicView(saveConn(conn.id, patch))));
  }
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
      const target = `${ZALO_OAUTH_BASE}/v4/oa/permission?app_id=${appId}&redirect_uri=${encodeURIComponent(PUBLIC_URL + "/oauth/callback")}&state=${encodeURIComponent(st)}`;
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
      // Zalo BẮT BUỘC 200 OK cho cả lần Kiểm tra lẫn mọi sự kiện; luôn ACK 200.
      send(200, JSON.stringify({ ok: true }));
      const mm = url.pathname.match(/^\/webhook\/zalo\/c\/([a-z0-9]+)\/([a-z0-9]+)$/);
      const conn = mm && connOf(mm[1]);
      // Token nằm trong đường dẫn là thứ xác thực đáng tin ở đây: Zalo cho đặt URL
      // tuỳ ý, còn công thức mac của họ thì mỗi app một kiểu.
      if (!conn || !safeEqualHex(String(conn.webhookToken || ""), String(mm[2] || ""))) {
        log("conn.webhook.bad", {});
        return;
      }
      saveConn(conn.id, { lastEventAt: Date.now() });
      let ev = null;
      try { ev = JSON.parse(raw || "{}"); } catch { log("conn.webhook.bad_json", { conn: conn.id }); return; }
      log("conn.webhook.received", { conn: conn.id, name: ev?.event_name || "" });
      handleZaloEvent(ev, connOf(conn.id))
        .then(() => { if (String(ev?.event_name || "").startsWith("user_send")) saveConn(conn.id, { lastInboundAt: Date.now() }); })
        .catch((e) => log("conn.zalo.handle.fail", { conn: conn.id, error: String(e) }));
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
    if (url.pathname.startsWith("/webhook/chatwoot/c/") && req.method === "POST") {
      const raw = await readBody(req);
      const cid = url.pathname.replace(/^\/webhook\/chatwoot\/c\//, "");
      const conn = connOf(cid);
      if (!conn) return send(404, JSON.stringify({ ok: false, error: "unknown_connection" }));
      // Mỗi hộp thư ký bằng secret của riêng nó, nên phải xác minh bằng secret của
      // đúng kết nối này — dùng chung một secret toàn cầu là cho tenant A ký thay B.
      const verdict = verifyChatwootSignature(raw, req.headers, Date.now(), conn.cwWebhookSecret);
      if (!verdict.ok) {
        log("conn.cw.sig.reject", { conn: conn.id, reason: verdict.reason });
        return send(401, JSON.stringify({ ok: false, error: verdict.reason }));
      }
      send(200, JSON.stringify({ ok: true }));
      let payload = null;
      try { payload = JSON.parse(raw || "{}"); } catch { return; }
      handleChatwootEvent(payload, conn)
        .then(() => saveConn(conn.id, { lastOutboundAt: Date.now() }))
        .catch((e) => log("conn.cw.handle.fail", { conn: conn.id, error: String(e) }));
      return;
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
export { verifyZaloSignature, verifyChatwootSignature, extractZaloText, handleChatwootEvent, handleZaloEvent, legacyConn, boxOf, cwTargetOf, connPublicView, state };
