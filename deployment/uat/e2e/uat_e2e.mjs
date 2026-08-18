/* eslint-disable no-console -- this is a command-line harness: its report on stdout
   is the deliverable, and there is no other channel to write it to. */
// Browser E2E against the isolated LLA CRM UAT stack.
//
// A real Chromium drives the running instance at an exact image digest. Every step
// asserts something the browser actually rendered or the server actually answered —
// nothing passes merely because a request did not throw. Screenshots and a
// machine-readable summary land in the output directory.
//
//   node uat_e2e.mjs http://127.0.0.1:4185 ./out
//
// Requires UAT_ADMIN_EMAIL and UAT_ADMIN_PASSWORD for the synthetic administrator.
import pw from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const { chromium } = pw;
const BASE = process.argv[2] || 'http://127.0.0.1:4185';
const OUT = process.argv[3] || './out';
fs.mkdirSync(OUT, { recursive: true });

const results = [];
const consoleErrors = [];
const failedRequests = [];
const navigationAborted = [];
let page;
let stepIndex = 0;
let accountId = null;
let authHeaders = null;

const slug = s =>
  s
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 55);
const assert = (condition, message) => {
  if (!condition) throw new Error(message);
};

async function step(name, fn) {
  stepIndex += 1;
  const id = String(stepIndex).padStart(2, '0');
  const started = Date.now();
  try {
    const detail = await fn();
    if (page)
      await page
        .screenshot({ path: path.join(OUT, `${id}-${slug(name)}.png`) })
        .catch(() => {});
    results.push({
      id,
      name,
      status: 'PASS',
      ms: Date.now() - started,
      detail: detail ?? null,
    });
    console.log(
      `PASS  ${id} ${name}${detail ? ` — ${JSON.stringify(detail)}` : ''}`
    );
  } catch (error) {
    if (page)
      await page
        .screenshot({
          path: path.join(OUT, `${id}-${slug(name)}-FAIL.png`),
          fullPage: true,
        })
        .catch(() => {});
    results.push({
      id,
      name,
      status: 'FAIL',
      ms: Date.now() - started,
      error: String((error && error.message) || error),
    });
    console.log(`FAIL  ${id} ${name} — ${error && error.message}`);
  }
}

const run = async () => {
  const browser = await chromium.launch({
    args: ['--no-sandbox', '--disable-dev-shm-usage'],
  });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 900 },
  });
  page = await context.newPage();
  page.on('console', m => {
    if (m.type() === 'error') consoleErrors.push(m.text());
  });
  page.on('requestfailed', r => {
    // ERR_ABORTED is what a still-in-flight XHR reports when the harness navigates
    // away from the page that started it. That is the harness, not the application,
    // so it is recorded separately rather than counted as a failure.
    const why = r.failure()?.errorText || '';
    const entry = `${r.method()} ${r.url()} ${why}`;
    (why.includes('ERR_ABORTED') ? navigationAborted : failedRequests).push(
      entry
    );
  });

  await step(
    'health endpoint identifies the product and both data services',
    async () => {
      const response = await page.request.get(`${BASE}/api`);
      assert(response.ok(), `/api returned ${response.status()}`);
      const body = await response.json();
      assert(body.product === 'LLA CRM', `product is ${body.product}`);
      assert(
        body.queue_services === 'ok',
        `queue_services is ${body.queue_services}`
      );
      assert(
        body.data_services === 'ok',
        `data_services is ${body.data_services}`
      );
      return {
        version: body.version,
        compatibility: `${body.compatibility_product} ${body.compatibility_version}`,
      };
    }
  );

  await step(
    'login screen renders under LLA branding, not upstream branding',
    async () => {
      const response = await page.goto(`${BASE}/app/login`, {
        waitUntil: 'networkidle',
        timeout: 60000,
      });
      assert(
        response && response.status() < 400,
        `login page returned ${response && response.status()}`
      );
      await page.waitForSelector(
        'input[name="email_address"], input[type="email"]',
        { timeout: 45000 }
      );
      const title = await page.title();
      const body = await page.textContent('body');
      assert(!/chatwoot/i.test(title), `page title still says ${title}`);
      assert(
        !/chatwoot/i.test(body),
        'login page still renders upstream branding'
      );
      return { title };
    }
  );

  await step('a synthetic administrator can log in', async () => {
    await page.fill(
      'input[name="email_address"], input[type="email"]',
      process.env.UAT_ADMIN_EMAIL
    );
    await page.fill(
      'input[name="password"], input[type="password"]',
      process.env.UAT_ADMIN_PASSWORD
    );
    await Promise.all([
      page.waitForURL(/\/app\/accounts\/\d+/, { timeout: 60000 }),
      page.click('button[type="submit"]'),
    ]);
    accountId = page.url().match(/accounts\/(\d+)/)[1];
    // Reuse the session the browser was actually issued, so the API assertions below
    // travel the same authorization path a real operator does.
    const cookies = await context.cookies();
    const session = cookies.find(c => c.name === 'cw_d_session_info');
    assert(session, 'no session cookie was issued');
    const info = JSON.parse(decodeURIComponent(session.value));
    authHeaders = {
      'access-token': info['access-token'],
      client: info.client,
      uid: info.uid,
      'token-type': 'Bearer',
    };
    return { accountId, uid: info.uid };
  });

  await step('the dashboard renders for the synthetic tenant', async () => {
    await page.waitForSelector(
      'text=/Conversations|Hội thoại|Inbox|Contacts/i',
      { timeout: 45000 }
    );
    return { url: page.url() };
  });

  await step('the contacts page lists the synthetic contact', async () => {
    await page.goto(`${BASE}/app/accounts/${accountId}/contacts`, {
      waitUntil: 'networkidle',
    });
    await page.waitForSelector('text=/UAT Synthetic Contact/i', {
      timeout: 45000,
    });
    return { accountId };
  });

  await step('the seeded conversation is readable over the API', async () => {
    const response = await page.request.get(
      `${BASE}/api/v1/accounts/${accountId}/conversations`,
      { headers: authHeaders }
    );
    assert(response.ok(), `conversations returned ${response.status()}`);
    const payload = await response.json();
    const conversations = payload.data?.payload ?? payload.payload ?? [];
    assert(
      conversations.length >= 1,
      `expected a seeded conversation, saw ${conversations.length}`
    );
    return { count: conversations.length };
  });

  await step('the inbox list shows the synthetic API inbox', async () => {
    const response = await page.request.get(
      `${BASE}/api/v1/accounts/${accountId}/inboxes`,
      { headers: authHeaders }
    );
    assert(response.ok(), `inboxes returned ${response.status()}`);
    const payload = await response.json();
    const names = (payload.payload ?? []).map(i => i.name);
    assert(
      names.includes('UAT API Inbox'),
      `inbox names were ${JSON.stringify(names)}`
    );
    return { names };
  });

  await step('the help center portal is listed in the dashboard', async () => {
    await page.goto(`${BASE}/app/accounts/${accountId}/portals`, {
      waitUntil: 'networkidle',
    });
    await page.waitForSelector('text=/UAT Portal/i', { timeout: 45000 });
    return { accountId };
  });

  await step(
    'the public help center serves the published article',
    async () => {
      const response = await page.goto(`${BASE}/hc/uat-portal/en`, {
        waitUntil: 'domcontentloaded',
      });
      assert(
        response && response.status() < 400,
        `public portal returned ${response && response.status()}`
      );
      const text = await page.textContent('body');
      assert(
        /UAT/i.test(text),
        'the public portal did not render the seeded portal'
      );
      return { status: response.status() };
    }
  );

  await step(
    'custom-domain status answers from the LLA lifecycle with the provider off',
    async () => {
      const response = await page.request.get(
        `${BASE}/api/v1/accounts/${accountId}/portals/uat-portal/ssl_status`,
        { headers: authHeaders }
      );
      assert(response.ok(), `ssl_status returned ${response.status()}`);
      const body = await response.text();
      assert(
        !/api_token|"secret"|BEGIN [A-Z ]*PRIVATE KEY/i.test(body),
        'ssl_status leaked a credential-shaped value'
      );
      return {
        status: response.status(),
        keys: Object.keys(JSON.parse(body)).slice(0, 10),
      };
    }
  );

  await step('an unknown portal slug answers 404, not 500', async () => {
    const response = await page.request.get(
      `${BASE}/api/v1/accounts/${accountId}/portals/no-such-portal`,
      { headers: authHeaders }
    );
    assert(response.status() === 404, `expected 404, got ${response.status()}`);
    return { status: response.status() };
  });

  await step('a cross-tenant account id is refused', async () => {
    const other = Number(accountId) + 999;
    const response = await page.request.get(
      `${BASE}/api/v1/accounts/${other}/conversations`,
      { headers: authHeaders }
    );
    assert(
      [401, 403, 404].includes(response.status()),
      `expected a refusal, got ${response.status()}`
    );
    return { status: response.status() };
  });

  await step('an unauthenticated request is refused', async () => {
    const anonContext = await browser.newContext();
    const anonPage = await anonContext.newPage();
    const response = await anonPage.request.get(
      `${BASE}/api/v1/accounts/${accountId}/conversations`
    );
    assert(
      [401, 403, 404].includes(response.status()),
      `expected a refusal, got ${response.status()}`
    );
    await anonContext.close();
    return { status: response.status() };
  });

  await step('the websocket endpoint accepts an upgrade', async () => {
    const upgraded = await page.evaluate(
      base =>
        new Promise(resolve => {
          const url = `${base.replace(/^http/, 'ws')}/cable`;
          const socket = new WebSocket(url);
          const done = value => {
            try {
              socket.close();
            } catch (_) {
              /* ignore */
            }
            resolve(value);
          };
          socket.onopen = () => done('open');
          socket.onerror = () => done('error');
          setTimeout(() => done('timeout'), 10000);
        }),
      BASE
    );
    assert(upgraded === 'open', `websocket handshake was ${upgraded}`);
    return { cable: upgraded };
  });

  // `SwaggerController#respond` serves the browsable API documentation only in
  // development and test. A production-mode UAT must therefore answer 404, and that
  // is the posture being asserted — not an outage. Whether the docs should be
  // exposed on an internal UAT host at all is an owner decision.
  await step(
    'the API documentation surface is deliberately not exposed in production mode',
    async () => {
      const response = await page.request.get(`${BASE}/swagger/index.html`);
      assert(
        response.status() === 404,
        `expected 404 in production mode, got ${response.status()}`
      );
      return { status: response.status() };
    }
  );

  await step(
    'signing out invalidates the session and returns to the login screen',
    async () => {
      const signOut = await page.request.delete(`${BASE}/auth/sign_out`, {
        headers: authHeaders,
      });
      assert(
        [200, 204, 404].includes(signOut.status()),
        `sign_out returned ${signOut.status()}`
      );
      const afterSignOut = await page.request.get(
        `${BASE}/api/v1/accounts/${accountId}/conversations`,
        { headers: authHeaders }
      );
      assert(
        [401, 403].includes(afterSignOut.status()),
        `the old token still works after sign out (${afterSignOut.status()})`
      );
      await context.clearCookies();
      await page.goto(`${BASE}/app/login`, { waitUntil: 'domcontentloaded' });
      await page.waitForSelector(
        'input[name="email_address"], input[type="email"]',
        { timeout: 30000 }
      );
      return { signOut: signOut.status(), reusedToken: afterSignOut.status() };
    }
  );

  await browser.close();
};

run()
  .catch(error => {
    results.push({
      id: '99',
      name: 'harness',
      status: 'FAIL',
      error: String((error && error.message) || error),
    });
    console.log(`FAIL  harness — ${error && error.message}`);
  })
  .finally(() => {
    const summary = {
      base: BASE,
      total: results.length,
      passed: results.filter(r => r.status === 'PASS').length,
      failed: results.filter(r => r.status === 'FAIL').length,
      consoleErrors,
      failedRequests,
      navigationAbortedRequests: navigationAborted,
      results,
    };
    fs.writeFileSync(
      path.join(OUT, 'e2e-results.json'),
      JSON.stringify(summary, null, 2)
    );
    console.log(
      `\n${summary.passed}/${summary.total} passed, ${summary.failed} failed`
    );
    console.log(
      `console errors: ${consoleErrors.length}; genuinely failed requests: ${failedRequests.length}`
    );
    process.exit(summary.failed === 0 ? 0 : 1);
  });
