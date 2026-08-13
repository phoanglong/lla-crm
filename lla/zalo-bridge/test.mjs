// Kiểm thử nhanh (node --test) — chạy với NODE_ENV=test
import { test } from "node:test";
import assert from "node:assert";
import { createHash } from "node:crypto";

process.env.NODE_ENV = "test";
process.env.ZALO_APP_ID = "123";
process.env.ZALO_APP_SECRET = "secret";
process.env.DATA_DIR = "/tmp/zbridge-test-data";
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
