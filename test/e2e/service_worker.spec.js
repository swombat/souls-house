import { expect, test } from '@playwright/test';

// The installable app's service worker with the worker in control of the page (the default).
// recording_guard.spec.js blocks the worker so its page.route deploy simulation can reach the
// requests; this spec checks the worker does not change what those tests rely on: an Inertia GET
// from a build older than the server still meets the server's 409, untouched by the worker.

test.describe('installable app service worker', () => {
  let setup;

  test.beforeEach(async ({ page, request }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `service-worker-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();

    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
  });

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  async function openControlledConversation(page, request) {
    const response = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 2, prefix: 'Under the worker' },
    });
    expect(response.ok()).toBe(true);
    const fixture = await response.json();
    const url = `/accounts/${setup.account_id}/chats/${fixture.chat_id}`;
    await page.goto(url);
    await page.evaluate(() => navigator.serviceWorker.ready);
    // The worker claims clients on activate; a reload guarantees this page is controlled.
    if (!(await page.evaluate(() => Boolean(navigator.serviceWorker.controller)))) await page.reload();
    await expect.poll(() => page.evaluate(() => Boolean(navigator.serviceWorker.controller))).toBe(true);
    await expect(page.getByTestId('message-composer')).toBeVisible();
    return url;
  }

  test('a stale Inertia request still meets the deploy 409 through the worker', async ({ page, request }) => {
    const url = await openControlledConversation(page, request);

    const stale = await page.evaluate(async (path) => {
      const response = await fetch(path, {
        headers: {
          'X-Inertia': 'true',
          'X-Inertia-Version': 'build-before-the-deploy',
          Accept: 'text/html, application/xhtml+xml',
        },
      });
      return { status: response.status, location: response.headers.get('X-Inertia-Location') };
    }, url);
    expect(stale.status).toBe(409);
    expect(stale.location).toContain(url);
  });

  test('a current Inertia request passes through the worker unchanged', async ({ page, request }) => {
    const url = await openControlledConversation(page, request);

    const current = await page.evaluate(async (path) => {
      // Inertia keeps the current page object, version included, in history state.
      const version = window.history.state?.page?.version;
      const response = await fetch(path, {
        headers: {
          'X-Inertia': 'true',
          'X-Inertia-Version': version ?? '',
          Accept: 'text/html, application/xhtml+xml',
        },
      });
      const body = await response.json();
      return { status: response.status, inertia: response.headers.get('X-Inertia'), component: body.component };
    }, url);
    expect(current.status).toBe(200);
    expect(current.inertia).toBe('true');
    expect(current.component).toBeTruthy();
  });

  test('the worker never stores conversation pages', async ({ page, request }) => {
    await openControlledConversation(page, request);
    const cached = await page.evaluate(async () => {
      const urls = [];
      for (const key of await caches.keys()) {
        const cache = await caches.open(key);
        for (const req of await cache.keys()) urls.push(new URL(req.url).pathname);
      }
      return urls;
    });
    expect(cached.filter((path) => !path.startsWith('/vite/assets/'))).toEqual([]);
  });
});
