import { expect, test } from '@playwright/test';

// A deploy changes the asset version. The next Inertia request from a page built before it
// gets a 409, and Inertia replaces the page: a voice note still being recorded is lost.
// These tests make the page "stale" at the transport boundary (rewriting X-Inertia-Version on
// its requests), record with Chromium's fake microphone, and check the real Rails, Inertia and
// axios wiring rather than the unit tests' mocks. Transcription is stubbed (no speech provider
// in test) but returns a real signed audio blob, as production does.

test.use({
  permissions: ['microphone'],
  launchOptions: { args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] },
});

test.describe('recording survives a deploy', () => {
  let setup;
  let stale;
  let dialogs;
  let inertiaGets;

  test.beforeEach(async ({ page, request }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `recording-guard-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    stale = false;
    dialogs = [];
    inertiaGets = [];

    page.on('dialog', (dialog) => {
      dialogs.push(dialog.message());
      dialog.dismiss();
    });
    page.on('request', (req) => {
      if (stale && req.method() === 'GET' && req.headers()['x-inertia']) inertiaGets.push(req.url());
    });
    // One deploy: once the server has told the page it is stale, the page it loads next is the
    // new build.
    page.on('response', (response) => {
      if (response.status() === 409 && response.headers()['x-inertia-location']) stale = false;
    });
    await page.route('**/*', (route) => {
      const headers = route.request().headers();
      if (!stale || !headers['x-inertia']) return route.fallback();
      return route.fallback({ headers: { ...headers, 'x-inertia-version': 'build-before-the-deploy' } });
    });

    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
  });

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  async function stubTranscription(page, request, text) {
    const blob = await (await request.post('/test/e2e/audio_blob')).json();
    await page.route('**/transcription', (route) => route.fulfill({ json: { text, audio_signed_id: blob.signed_id } }));
  }

  async function openConversation(page, request) {
    const response = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 3, prefix: 'Before the deploy' },
    });
    expect(response.ok()).toBe(true);
    const fixture = await response.json();
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    await expect(page.getByTestId('message-composer')).toBeVisible();
    return fixture;
  }

  const markDocument = (page) => page.evaluate(() => (window.__sameDocument = true));
  const sameDocument = (page) => page.evaluate(() => window.__sameDocument === true);

  test('a refresh arriving mid-recording is held, then replayed once the voice note is sent', async ({
    page,
    request,
  }) => {
    const fixture = await openConversation(page, request);
    await markDocument(page);
    stale = true;

    await page.getByTitle('Record voice message').click();
    await expect(page.getByTitle('Stop recording')).toBeVisible();

    await request.post('/test/e2e/assistant_message', {
      data: { chat_id: fixture.chat_id, content: 'Landed while Daniel was dictating' },
    });
    await page.waitForTimeout(2500);
    expect(inertiaGets).toEqual([]);
    expect(await sameDocument(page)).toBe(true);
    await expect(page.getByTitle('Stop recording')).toBeVisible();

    await stubTranscription(page, request, 'A long voice note that must not be lost');
    await page.getByTitle('Stop recording').click();

    // Once the message is sent the held refresh goes out, meets the new build, and the page
    // reloads with everything in it.
    await expect.poll(() => sameDocument(page).catch(() => false)).toBe(false);
    await expect(page.getByText('A long voice note that must not be lost')).toBeVisible();
    await expect(page.getByText('Landed while Daniel was dictating')).toBeVisible();
    expect(dialogs).toEqual([]);
  });

  test('a refresh already in flight when recording starts cannot reload the page', async ({ page, request }) => {
    const fixture = await openConversation(page, request);
    await markDocument(page);

    let releaseRefresh;
    const refreshSeen = new Promise((resolve) => {
      page.route(`**/accounts/${setup.account_id}/chats/${fixture.chat_id}`, async (route) => {
        const headers = route.request().headers();
        if (route.request().method() !== 'GET' || !headers['x-inertia']) return route.fallback();
        resolve();
        await new Promise((go) => (releaseRefresh = go));
        return route.fallback();
      });
    });

    await request.post('/test/e2e/assistant_message', {
      data: { chat_id: fixture.chat_id, content: 'Refresh started before the mic' },
    });
    await refreshSeen;

    await page.getByTitle('Record voice message').click();
    await expect(page.getByTitle('Stop recording')).toBeVisible();

    stale = true;
    const conflict = page.waitForResponse((response) => response.status() === 409);
    releaseRefresh();
    await conflict;
    await page.waitForTimeout(1500);

    expect(await sameDocument(page)).toBe(true);
    await expect(page.getByTitle('Stop recording')).toBeVisible();
    expect(dialogs).toEqual([]);
  });

  test('starting a new conversation by voice on a stale page creates it once and opens it', async ({
    page,
    request,
  }) => {
    await page.goto(`/accounts/${setup.account_param}/chats/new`);
    await expect(page.getByTestId('message-composer')).toBeVisible();
    const chatCount = async () =>
      (await (await request.post('/test/e2e/state', { data: { run_id: setup.run_id } })).json()).account.chats.length;
    const before = await chatCount();
    await stubTranscription(page, request, 'A first message spoken, not typed');
    await markDocument(page);

    await page.getByTitle('Record voice message').click();
    await expect(page.getByTitle('Stop recording')).toBeVisible();
    stale = true; // the deploy lands mid-recording
    await page.waitForTimeout(1000);
    expect(await sameDocument(page)).toBe(true);
    await page.getByTitle('Stop recording').click();

    // The POST creates the chat, its redirect meets the new build (409), and Inertia loads the
    // new conversation. The recording guard must not swallow that 409.
    await expect(page).toHaveURL(/\/chats\/(?!new$)[^/]+$/);
    await expect(page.getByText('A first message spoken, not typed')).toBeVisible();
    expect(dialogs).toEqual([]);

    expect(await chatCount()).toBe(before + 1);
  });
});
