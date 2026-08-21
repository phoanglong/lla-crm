// Kiểm thử HTTP thật: cửa /webhook/chatwoot có thực sự khoá không.
// Hàm verify được kiểm ở test.mjs; ở đây kiểm phần đấu dây của route, vì đó mới
// là chỗ lỗ hổng từng nằm — hàm có đúng mà route không gọi thì vẫn mở toang.
import { test, after } from "node:test";
import assert from "node:assert";
import { createHmac } from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const HERE = dirname(fileURLToPath(import.meta.url));
const PORT = 18787;
const SECRET = "cw-inbox-secret";
const BASE = `http://127.0.0.1:${PORT}`;

const child = spawn(process.execPath, [join(HERE, "server.mjs")], {
  env: {
    ...process.env,
    NODE_ENV: "http-test",
    PORT: String(PORT),
    DATA_DIR: "/tmp/zbridge-http-test",
    ZALO_APP_ID: "123",
    ZALO_APP_SECRET: "secret",
    CHATWOOT_URL: "http://127.0.0.1:1",
    CHATWOOT_API_TOKEN: "t",
    CHATWOOT_ACCOUNT_ID: "1",
    CHATWOOT_INBOX_ID: "1",
    CHATWOOT_WEBHOOK_SECRET: SECRET,
    BRIDGE_PUBLIC_URL: BASE,
  },
  stdio: "ignore",
});
after(() => child.kill());

async function waitForBoot() {
  for (let i = 0; i < 50; i++) {
    try { if ((await fetch(`${BASE}/healthz`)).ok) return; } catch { /* chưa lên */ }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error("bridge không khởi động");
}
await waitForBoot();

const post = (body, headers) =>
  fetch(`${BASE}/webhook/chatwoot`, { method: "POST", headers: { "content-type": "application/json", ...headers }, body });

test("healthz báo cửa CRM đã khoá", async () => {
  const body = await (await fetch(`${BASE}/healthz`)).json();
  assert.equal(body.chu_ky_crm, true);
});

test("gửi tin không chữ ký bị chặn 401", async () => {
  const payload = JSON.stringify({ event: "message_created", message_type: "outgoing", conversation: { id: 1 }, content: "giả mạo" });
  const res = await post(payload, {});
  assert.equal(res.status, 401);
  assert.equal((await res.json()).error, "missing_signature");
});

test("gửi tin có chữ ký đúng được nhận 200", async () => {
  const payload = JSON.stringify({ event: "message_created", message_type: "outgoing", conversation: { id: 1 }, content: "thật" });
  const ts = String(Math.floor(Date.now() / 1000));
  const sig = "sha256=" + createHmac("sha256", SECRET).update(`${ts}.${payload}`).digest("hex");
  const res = await post(payload, { "x-chatwoot-signature": sig, "x-chatwoot-timestamp": ts });
  assert.equal(res.status, 200);
});
