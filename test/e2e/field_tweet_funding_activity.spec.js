import { expect, test } from '@playwright/test';

test.use({ actionTimeout: 10_000 });

test('funding discovery updates no-source and paused panels without losing drafts', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `tweet-funding-${Date.now()}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  const mutate = async (operation) => {
    const response = await request.post('/test/e2e/tweet_stream_fixture', {
      data: { account_id: setup.account_id, operation },
    });
    expect(response.ok()).toBe(true);
  };
  let confirmed = false;
  await page.routeWebSocket('**/cable', (socket) => {
    socket.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.type === 'confirm_subscription' && JSON.parse(message.identifier).model === 'FieldTweetStream')
        confirmed = true;
      socket.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('tweet_stream')) reloads.push(props);
  });
  try {
    await mutate('enable_unfunded');
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/field?tab=tweets`);
    await expect(page.getByTestId('tweet-stream-needs-integration')).toBeVisible();
    await expect.poll(() => confirmed).toBe(true);
    await expect.poll(() => reloads.length).toBeGreaterThan(0);
    await page.waitForLoadState('networkidle');
    // Let all initial layout/page subscriptions finish their debounced
    // catch-up before measuring the isolated funding mutation.
    await page.waitForTimeout(700);
    await page.waitForLoadState('networkidle');
    const beforeFunding = reloads.length;
    await mutate('fund');
    const handle = page.getByLabel('Follow an X handle', { exact: true });
    await expect(handle).toBeVisible();
    await page.waitForLoadState('networkidle');
    expect(reloads.at(-1)).toEqual(['tweet_stream']);
    expect(reloads.length - beforeFunding).toBeLessThanOrEqual(2);
    await handle.fill('draft_handle');
    await mutate('unfund');
    await expect(page.getByTestId('tweet-stream-needs-integration')).toBeVisible();
    await mutate('fund');
    await expect(handle).toHaveValue('draft_handle');

    await mutate('create');
    await expect(page.getByRole('link', { name: '@example', exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Pause', exact: true }).click();
    await expect(page.getByTestId('field-tweet-stream-state')).toContainText('Paused');
    const limit = page.getByLabel('Monthly limit on your TwitterAPI.io spend (USD)');
    await limit.fill('9.');
    await page.getByLabel('Include its replies').uncheck();
    await mutate('unfund');
    await expect(page.getByText('Nobody pays for collection right now:', { exact: false })).toBeVisible();
    await expect(page.getByTestId('field-tweet-stream-state')).toContainText('Paused');
    await mutate('fund');
    await expect(limit).toHaveValue('9.');
    await expect(page.getByLabel('Include its replies')).not.toBeChecked();
    await expect(page.getByTestId('field-tweet-stream-state')).toContainText('Paused');

    await mutate('limits');
    await expect(page.getByText('Imported today:', { exact: false })).toContainText('of 37');
    await expect(limit).toHaveValue('9.');
    await expect(page.getByLabel('Include its replies')).not.toBeChecked();

    await page.waitForLoadState('networkidle');
    const beforeQuiet = reloads.length;
    await mutate('funding_bookkeeping');
    await page.waitForTimeout(900);
    expect(reloads).toHaveLength(beforeQuiet);
    await page.screenshot({ path: testInfo.outputPath('tweet-funding-live-draft.png'), fullPage: true });
    await mutate('feature_off');
    await expect(page.getByTestId('field-tweet-stream-panel')).toHaveCount(0);
    await mutate('feature_on');
    await expect(page.getByTestId('field-tweet-stream-panel')).toBeVisible();
    // Feature disable deliberately resets the unavailable form, unlike a
    // funding or read-only status refresh.
    await expect.poll(async () => Number(await limit.inputValue())).toBe(5);
    await expect(page.getByLabel('Include its replies')).toBeChecked();
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
