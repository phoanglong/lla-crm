// Kiểm thử nhanh (node --test) — chạy với NODE_ENV=test
import { test } from "node:test";
import assert from "node:assert";
import { createHash, createHmac } from "node:crypto";

process.env.NODE_ENV = "test";
process.env.ZALO_APP_ID = "123";
process.env.ZALO_APP_SECRET = "secret";
process.env.DATA_DIR = "/tmp/zbridge-test-data";
process.env.CHATWOOT_WEBHOOK_SECRET = "cw-inbox-secret";
const { verifyZaloSignature, extractZaloText } = await import("./server.mjs");

test("chữ ký Zalo hợp lệ được chấp nhận", () => {
  const raw = JSON.stringify({ event_name: "user_send_text", timestamp: "1700000000000" });
  const mac = createHash("sha256").update("123" + raw + "1700000000000" + "secret").digest("hex");
  assert.equal(verifyZaloSignature(raw, { "x-zevent-signature": "mac=" + mac }), true);
});

test("chữ ký sai bị từ chối", () => {
  const raw = JSON.stringify({ event_name: "user_send_text", timestamp: "1700000000000" });
  assert.equal(verifyZaloSignature(raw, { "x-zevent-signature": "mac=deadbeef" }), false);
});

test("thiếu chữ ký bị từ chối", () => {
  assert.equal(verifyZaloSignature("{}", {}), false);
});

test("trích text tin nhắn", () => {
  assert.equal(extractZaloText({ message: { text: "xin chào" } }), "xin chào");
});

test("trích đính kèm ảnh", () => {
  const out = extractZaloText({ message: { attachments: [{ type: "image", payload: { url: "http://x/y.jpg" } }] } });
  assert.equal(out, "[image] http://x/y.jpg");
});

test("tin không nội dung trả null", () => {
  assert.equal(extractZaloText({ message: {} }), null);
});

// ---------- Chữ ký webhook của LLA CRM ----------
// `secret` phải được nạp trước khi import server.mjs (module đọc ENV một lần).
const { verifyChatwootSignature } = await import("./server.mjs");
const cwSign = (ts, body) =>
  "sha256=" + createHmac("sha256", process.env.CHATWOOT_WEBHOOK_SECRET).update(`${ts}.${body}`).digest("hex");

test("webhook CRM có chữ ký đúng được chấp nhận", () => {
  const body = JSON.stringify({ event: "message_created" });
  const ts = String(Math.floor(Date.now() / 1000));
  const out = verifyChatwootSignature(body, { "x-chatwoot-signature": cwSign(ts, body), "x-chatwoot-timestamp": ts });
  assert.equal(out.ok, true);
});

test("webhook CRM không chữ ký bị từ chối", () => {
  const out = verifyChatwootSignature("{}", {});
  assert.deepEqual(out, { ok: false, reason: "missing_signature" });
});

test("webhook CRM sai chữ ký bị từ chối", () => {
  const body = JSON.stringify({ event: "message_created" });
  const ts = String(Math.floor(Date.now() / 1000));
  const out = verifyChatwootSignature(body, { "x-chatwoot-signature": "sha256=deadbeef", "x-chatwoot-timestamp": ts });
  assert.deepEqual(out, { ok: false, reason: "bad_signature" });
});

test("phát lại webhook CRM cũ bị từ chối", () => {
  const body = JSON.stringify({ event: "message_created" });
  const ts = String(Math.floor(Date.now() / 1000) - 3600);
  const out = verifyChatwootSignature(body, { "x-chatwoot-signature": cwSign(ts, body), "x-chatwoot-timestamp": ts });
  assert.deepEqual(out, { ok: false, reason: "stale_timestamp" });
});

test("thân tin bị sửa sau khi ký bị từ chối", () => {
  const body = JSON.stringify({ event: "message_created", content: "xin chào" });
  const ts = String(Math.floor(Date.now() / 1000));
  const sig = cwSign(ts, body);
  const tampered = JSON.stringify({ event: "message_created", content: "chuyển tiền đi" });
  const out = verifyChatwootSignature(tampered, { "x-chatwoot-signature": sig, "x-chatwoot-timestamp": ts });
  assert.deepEqual(out, { ok: false, reason: "bad_signature" });
});
