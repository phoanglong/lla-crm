// Luồng tin của MỘT kết nối riêng, chạy thật qua HTTP: Zalo giả + CRM giả.
// Điều đáng kiểm không phải "hàm có đúng không" mà là "tin của tenant B có rơi vào
// hộp thư của tenant A không" — chỉ chạy cả đường dây mới trả lời được.
import { test, after } from "node:test";
import assert from "node:assert";
import { createHmac } from "node:crypto";
import { createServer } from "node:http";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";

const HERE = dirname(fileURLToPath(import.meta.url));
const ADMIN = "admin-token-for-test";

function jsonServer(handler) {
  const calls = [];
  const srv = createServer(async (req, res) => {
    let body = "";
    req.on("data", (c) => (body += c));
    req.on("end", () => {
      let parsed = null;
      if (body) { try { parsed = JSON.parse(body); } catch { parsed = Object.fromEntries(new URLSearchParams(body)); } }
      const call = { method: req.method, url: req.url, body: parsed };
      calls.push(call);
      const out = handler(call) ?? { ok: true };
      res.writeHead(200, { "Content-Type": "application/json" });
      res.end(JSON.stringify(out));
    });
  });
  return { srv, calls, port: () => srv.address().port };
}
const listen = (srv) => new Promise((r) => srv.listen(0, "127.0.0.1", r));

// CRM giả: đủ để bắc cầu tạo liên hệ / hội thoại / tin nhắn.
const crmHandler = (call) => {
  if (call.url.includes("/contacts/search")) return { payload: [] };
  if (call.url.endsWith("/contacts") && call.method === "POST") return { payload: { contact: { id: 77 } } };
  if (call.url.includes("/conversations") && call.method === "POST" && !call.url.includes("/messages")) return { id: 88 };
  if (call.url.includes("/conversations") && call.method === "GET") return { payload: [] };
  return { ok: true };
};
const crm = jsonServer(crmHandler);
// Bản cài CRM thứ hai: kết nối riêng phải ghi vào ĐÂY, không phải vào CRM của ENV.
const crm2 = jsonServer(crmHandler);
// Zalo giả: listrecentchat để resolve, và message/cs cho chiều ra.
const zalo = jsonServer((call) => {
  if (call.url === "/v4/oa/access_token") {
    return { access_token: "at-tenant-b", refresh_token: "rt-tenant-b", expires_in: 3600 };
  }
  if (call.url.startsWith("/v2.0/oa/listrecentchat")) {
    // Webhook chỉ cho user_id_by_app; cầu phải khớp lại bằng nội dung tin để lấy
    // user_id thật — nên Zalo giả trả đúng hình dạng đó.
    return {
      data: [{
        from_id: "real-uid-9", from_display_name: "Chị Lan", from_avatar: "http://a/b.png",
        message: "cần hỗ trợ", src: 1,
      }],
    };
  }
  if (call.url === "/v3.0/oa/message/cs") return { error: 0 };
  return { error: 0 };
});
await listen(crm.srv);
await listen(crm2.srv);
await listen(zalo.srv);

const PORT = 18799;
const BASE = `http://127.0.0.1:${PORT}`;
const child = spawn(process.execPath, [join(HERE, "server.mjs")], {
  env: {
    ...process.env,
    NODE_ENV: "conn-test",
    PORT: String(PORT),
    DATA_DIR: mkdtempSync(join(tmpdir(), "zbridge-conn-")),
    ZALO_APP_ID: "111", ZALO_APP_SECRET: "s3cret",
    ZALO_API_BASE: `http://127.0.0.1:${zalo.port()}`,
    ZALO_OAUTH_BASE: `http://127.0.0.1:${zalo.port()}`,
    CHATWOOT_URL: `http://127.0.0.1:${crm.port()}`,
    CHATWOOT_API_TOKEN: "cw-token",
    CHATWOOT_ACCOUNT_ID: "1",
    CHATWOOT_INBOX_ID: "3",
    CHATWOOT_WEBHOOK_SECRET: "secret-cua-inbox-3",
    BRIDGE_ADMIN_TOKEN: ADMIN,
    BRIDGE_PUBLIC_URL: BASE,
    ZALO_VERIFY_SIGNATURE: "false",
  },
  stdio: "ignore",
});
after(() => { child.kill(); crm.srv.close(); crm2.srv.close(); zalo.srv.close(); });

for (let i = 0; i < 50; i++) {
  try { if ((await fetch(`${BASE}/healthz`)).ok) break; } catch { /* chưa lên */ }
  await new Promise((r) => setTimeout(r, 100));
}

const admin = (path, method = "GET", body) =>
  fetch(BASE + path, {
    method,
    headers: { "content-type": "application/json", "x-bridge-admin-token": ADMIN },
    body: body === undefined ? undefined : JSON.stringify(body),
  });

const created = await (await admin("/api/connections", "POST", {
  app_id: "2222222222", app_secret: "secret-cua-tenant-b", name: "OA Tenant B",
})).json();

test("kết nối mới trả đủ URL cần dán vào Zalo Developers", () => {
  assert.match(created.webhook_url, /\/webhook\/zalo\/c\/[a-z0-9]+\/[a-z0-9]+$/);
  assert.equal(created.chatwoot_webhook_url, `${BASE}/webhook/chatwoot/c/${created.id}`);
  assert.equal(created.oauth_url, `${BASE}/oauth/start?conn=${created.id}`);
  assert.equal(created.status.inbox_linked, false);
  assert.equal(created.status.authorized, false);
});

test("uỷ quyền OA cho kết nối riêng lưu token của chính nó", async () => {
  const res = await fetch(`${BASE}/oauth/callback?code=ma-uy-quyen&state=conn:${created.id}`);
  assert.equal(res.status, 200);
  const st = await (await admin(`/api/connections/${created.id}`)).json();
  assert.equal(st.status.authorized, true);
});

test("chưa gắn hộp thư thì tin đến KHÔNG rơi vào hộp thư của ENV", async () => {
  const before = crm.calls.length;
  await fetch(created.webhook_url, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ event_name: "user_send_text", sender: { id: "u-b-1" }, message: { text: "chào", msg_id: "m1" } }),
  });
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(crm.calls.length, before, "không được gọi CRM khi kết nối chưa có hộp thư");
  const st = await (await admin(`/api/connections/${created.id}`)).json();
  assert.equal(st.status.webhook_received, true, "vẫn phải ghi nhận là đã nhận webhook");
});

test("gắn hộp thư rồi thì tin đến vào ĐÚNG hộp thư của kết nối", async () => {
  await admin(`/api/connections/${created.id}`, "PATCH", {
    cw_account_id: "9", cw_inbox_id: "42", cw_webhook_secret: "secret-cua-inbox-42",
    cw_url: `http://127.0.0.1:${crm2.port()}`,
  });
  await fetch(created.webhook_url, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ event_name: "user_send_text", sender: { id: "u-b-2" }, message: { text: "cần hỗ trợ", msg_id: "m2" } }),
  });
  await new Promise((r) => setTimeout(r, 500));

  assert.equal(crm.calls.filter((c) => c.method === "POST").length, 0, "không được chạm vào CRM của ENV");
  const contact = crm2.calls.find((c) => c.method === "POST" && c.url.endsWith("/contacts"));
  const conv = crm2.calls.find((c) => c.method === "POST" && /\/conversations$/.test(c.url));
  const msg = crm2.calls.find((c) => c.method === "POST" && c.url.includes("/messages"));
  assert.ok(contact, "phải tạo liên hệ");
  assert.match(contact.url, /^\/api\/v1\/accounts\/9\//, "phải gọi vào account của kết nối, không phải account ENV");
  assert.equal(contact.body.inbox_id, 42);
  assert.equal(contact.body.name, "Chị Lan", "tên lấy từ listrecentchat");
  assert.equal(conv.body.inbox_id, 42);
  assert.equal(msg.body.content, "cần hỗ trợ");
  assert.equal(msg.body.message_type, "incoming");
});

test("token webhook sai thì tin bị bỏ", async () => {
  const before = crm.calls.length;
  await fetch(`${BASE}/webhook/zalo/c/${created.id}/saitoanbo`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ event_name: "user_send_text", sender: { id: "u-x" }, message: { text: "giả mạo", msg_id: "m3" } }),
  });
  await new Promise((r) => setTimeout(r, 300));
  assert.equal(crm.calls.length, before);
});

test("chiều ra: chữ ký của hộp thư khác bị từ chối, của chính nó thì qua", async () => {
  const payload = JSON.stringify({
    event: "message_created", message_type: "outgoing", private: false,
    conversation: { id: 88 }, content: "Chào chị Lan",
  });
  const sign = (secret, ts) => "sha256=" + createHmac("sha256", secret).update(`${ts}.${payload}`).digest("hex");
  const ts = String(Math.floor(Date.now() / 1000));
  const url = `${BASE}/webhook/chatwoot/c/${created.id}`;

  const wrong = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-chatwoot-signature": sign("secret-cua-inbox-3", ts), "x-chatwoot-timestamp": ts },
    body: payload,
  });
  assert.equal(wrong.status, 401, "secret của hộp thư khác không được đi qua");

  const right = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json", "x-chatwoot-signature": sign("secret-cua-inbox-42", ts), "x-chatwoot-timestamp": ts },
    body: payload,
  });
  assert.equal(right.status, 200);
  await new Promise((r) => setTimeout(r, 400));
  const sent = zalo.calls.find((c) => c.url === "/v3.0/oa/message/cs");
  assert.ok(sent, "phải gửi ra Zalo");
  assert.equal(sent.body.recipient.user_id, "real-uid-9", "gửi tới user_id thật đã resolve");
  assert.equal(sent.body.message.text, "Chào chị Lan");
});

test("kết nối không tồn tại trả 404", async () => {
  const res = await fetch(`${BASE}/webhook/chatwoot/c/khongcothat`, {
    method: "POST", headers: { "content-type": "application/json" }, body: "{}",
  });
  assert.equal(res.status, 404);
});

test("admin API vẫn đóng với ai không có token", async () => {
  const res = await fetch(`${BASE}/api/connections/${created.id}`);
  assert.equal(res.status, 401);
});

test("kết nối ENV (OA đang chạy thật) vẫn đi hộp thư cũ, không lẫn sang kết nối mới", async () => {
  const before = crm.calls.length;
  await fetch(`${BASE}/webhook/zalo`, {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ event_name: "user_send_text", sender: { id: "u-legacy-1" }, message: { text: "tin cũ", msg_id: "m-legacy" } }),
  });
  await new Promise((r) => setTimeout(r, 500));
  const fresh = crm.calls.slice(before);
  const contact = fresh.find((c) => c.method === "POST" && c.url.endsWith("/contacts"));
  assert.ok(contact, "kết nối ENV phải vẫn tạo được liên hệ");
  assert.match(contact.url, /^\/api\/v1\/accounts\/1\//, "phải vào account ENV");
  assert.equal(contact.body.inbox_id, 3, "phải vào hộp thư ENV");
});
