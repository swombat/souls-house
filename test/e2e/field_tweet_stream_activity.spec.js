import { expect, test } from '@playwright/test';

test.use({ actionTimeout: 10_000 });

test('source arrival, status and reconnect update an open panel without replacing its draft', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `tweet-status-${Date.now()}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  const mutate = async (operation) => {
    const response = await request.post('/test/e2e/tweet_stream_fixture', {
      data: { account_id: setup.account_id, operation },
    });
    expect(response.ok()).toBe(true);
  };
  let cable;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (socket) => {
    cable = socket;
    const server = socket.connectToServer();
    server.onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.type === 'confirm_subscription' && JSON.parse(message.identifier).model === 'FieldTweetStream')
        confirmed = true;
      if (!drop || !message.message) socket.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('tweet_stream')) reloads.push(props);
  });
  const editor = await page.context().newPage();
  try {
    await mutate('enable');
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}/field?tab=tweets`;
    await page.goto(base);
    await expect.poll(() => confirmed).toBe(true);
    await expect(page.getByTestId('tweet-stream-follow-form')).toBeVisible();
    await expect.poll(() => reloads.length).toBeGreaterThan(0);
    await page.waitForLoadState('networkidle');
    const beforeArrival = reloads.length;
    await mutate('create');
    await expect(page.getByRole('link', { name: '@example', exact: true })).toBeVisible();
    await page.waitForLoadState('networkidle');
    expect(reloads.length - beforeArrival).toBeLessThanOrEqual(2);
    expect(reloads.at(-1)).toEqual(['tweet_stream']);

    const limit = page.getByLabel('Monthly limit on your TwitterAPI.io spend (USD)');
    await limit.fill('7.');
    await page.getByLabel('Include its replies').uncheck();
    await editor.goto(base);
    await editor.getByRole('button', { name: 'Pause', exact: true }).click();
    await expect(page.getByTestId('field-tweet-stream-state')).toContainText('Paused');
    await expect(limit).toHaveValue('7.');
    await expect(page.getByLabel('Include its replies')).not.toBeChecked();

    // Lose the only resume marker. The reconnect itself must catch up.
    drop = true;
    await editor.getByRole('button', { name: 'Resume', exact: true }).click();
    await expect(editor.getByTestId('field-tweet-stream-state')).toContainText('Up to date');
    cable.close({ code: 1012, reason: 'Synthetic tweet status reconnect' });
    await expect(page.getByTestId('field-tweet-stream-state')).toContainText('Up to date', { timeout: 20_000 });
    drop = false;
    await expect(limit).toHaveValue('7.');
    await expect(page.getByLabel('Include its replies')).not.toBeChecked();
    expect(page.url()).toContain('?tab=tweets');

    await page.waitForLoadState('networkidle');
    const beforeQuiet = reloads.length;
    await mutate('bookkeeping');
    expect(
      (
        await request.post('/test/e2e/field_activity_fixture', {
          data: { account_id: setup.account_id, operation: 'chat' },
        })
      ).ok()
    ).toBe(true);
    await page.waitForTimeout(900); // negative assertion beyond the shared debounce
    expect(reloads).toHaveLength(beforeQuiet);
    const refreshed = page.waitForResponse(
      (res) => res.request().headers()['x-inertia-partial-data'] === 'tweet_stream'
    );
    await page.getByRole('button', { name: 'Refresh status' }).click();
    expect((await (await refreshed).json()).props.tweet_stream.refreshed_at).toBeTruthy();
    await expect(limit).toHaveValue('7.');
    await expect(page.getByTestId('tweet-stream-refreshed')).toContainText('Status as of refresh');
    await page.screenshot({ path: testInfo.outputPath('tweet-stream-live-draft.png'), fullPage: true });

    expect(
      (
        await request.post('/test/e2e/field_activity_fixture', {
          data: { account_id: setup.account_id, operation: 'arrive' },
        })
      ).ok()
    ).toBe(true);
    const beforeSearch = reloads.length;
    await page.goto(`${base}&q=live`);
    const results = page.getByTestId('field-search-result');
    await expect.poll(() => results.count()).toBeGreaterThan(0);
    await expect.poll(() => reloads.length).toBeGreaterThan(beforeSearch);
    await page.waitForLoadState('networkidle');
    const order = await results.allTextContents();
    const searchedUrl = page.url();
    await limit.fill('8.');
    const advanced = page.waitForResponse(
      async (res) =>
        res.request().headers()['x-inertia-partial-data'] === 'tweet_stream' &&
        (await res.json()).props.tweet_stream.source.last_success_at
    );
    await mutate('advance');
    await advanced;
    await expect(limit).toHaveValue('8.');
    expect(await results.allTextContents()).toEqual(order);
    expect(page.url()).toBe(searchedUrl);
  } finally {
    await editor.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
