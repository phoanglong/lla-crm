# UAT browser end-to-end harness

Drives a real Chromium against a running LLA CRM UAT stack and asserts what the
browser rendered and what the server answered. Every step writes a screenshot, and
`e2e-results.json` records the outcome, the console errors and the failed requests
so a run can be read without re-running it.

```
npm install -D playwright   # or: pnpm add -D playwright
npx playwright install chromium

UAT_ADMIN_EMAIL=... UAT_ADMIN_PASSWORD=... \
  node deployment/uat/e2e/uat_e2e.mjs http://127.0.0.1:4185 ./e2e-out
```

Both variables come from `deployment/uat/.env.uat`, which is not committed. The
harness exits non-zero if any step fails.

What it covers today: health and both data services; LLA branding on the login
screen; administrator login; dashboard render; the seeded contact, conversation and
inbox; the Help Center portal in the dashboard and its public page; the custom-domain
`ssl_status` payload with the provider OFF and no credential-shaped value in it; an
unknown portal slug answering 404 rather than 500; cross-tenant and unauthenticated
refusals; the ActionCable upgrade; the API documentation surface being deliberately
absent in production mode; and sign-out actually invalidating the token.

What it does **not** cover, and must before this is called a UAT acceptance run:
channel onboarding, inbound and outbound messages with duplicate/out-of-order/retry,
assignment and capacity, workflows, Captain RAG/auto-reply/copilot, Help Center
generation and search, the custom-domain lifecycle against a sandbox provider,
reporting/CSAT/export, plan/quota/override, and the audit and deletion paths.
