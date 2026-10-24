import { expect, test } from '@playwright/test';

test('an open Field gets arrivals, deletion and reconnect catch-up without chat noise or lost drafts', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(90_000);
  const runId = `field-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const mutate = async (operation, extra = {}) => {
    const result = await request.post('/test/e2e/field_activity_fixture', {
      data: { account_id: setup.account_id, operation, ...extra },
    });
    expect(result.ok()).toBe(true);
    return operation === 'arrive' ? result.json() : null;
  };
  let cable;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (socket) => {
    cable = socket;
    const server = socket.connectToServer();
    server.onMessage((raw) => {
      const data = JSON.parse(raw);
      if (data.type === 'confirm_subscription' && JSON.parse(data.identifier).model === 'FieldActivity') {
        confirmed = true;
      }
      if (!drop || !data.message) socket.send(raw);
    });
  });
  const fieldReloads = [];
  page.on('request', (req) => {
    const props = req.headers()['x-inertia-partial-data'] || '';
    if (props.split(',').includes('items')) fieldReloads.push(props);
  });
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}/field`;
    await page.goto(base);
    await expect.poll(() => confirmed).toBe(true);
    await expect.poll(() => fieldReloads.length).toBeGreaterThan(0);
    await page.waitForLoadState('networkidle');

    // A chat commit must not invalidate Field list/search props.
    const beforeChat = fieldReloads.length;
    await mutate('chat');
    await page.waitForTimeout(900); // deliberate negative assertion beyond the 300ms debounce
    expect(fieldReloads).toHaveLength(beforeChat);

    await page.getByTestId('field-new-note').click();
    await page.getByLabel('Name', { exact: true }).fill('My unsaved note');
    await page.getByLabel(/^Note/).fill('Do not lose these words');
    const beforeArrival = fieldReloads.length;
    const { note } = await mutate('arrive');
    await expect(page.getByText('Live arrival', { exact: true })).toBeAttached();
    await expect(page.getByLabel(/^Note/)).toHaveValue('Do not lose these words');
    await expect(page.getByRole('tab', { name: /Songs/ })).toContainText('1');
    await expect(page.getByRole('tab', { name: /Tweets/ })).toContainText('1');
    // Three records committed in one request must coalesce, not fan out per item.
    expect(fieldReloads.length - beforeArrival).toBeLessThanOrEqual(2);
    expect(fieldReloads.at(-1).split(',')).not.toContain('search');
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await page.getByText('Live arrival', { exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`item=note-${note}`));
    const selectedUrl = page.url();
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const noteDraft = page.getByPlaceholder('Write your whiteboard content here...');
    await noteDraft.fill('My existing-note draft');

    // The sole rename event is lost. Reconnect must catch up without a later write.
    await page.waitForLoadState('networkidle');
    drop = true;
    await mutate('rename', { note });
    cable.close({ code: 1012, reason: 'Synthetic reconnect' });
    const noteHeading = page.getByTestId('field-reader').getByRole('heading', { name: 'Renamed live note' });
    await expect(noteHeading).toBeVisible({ timeout: 20_000 });
    drop = false;
    expect(page.url()).toBe(selectedUrl);
    await expect(noteDraft).toHaveValue('My existing-note draft');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(page.getByText('Someone else edited this whiteboard')).toBeVisible();
    await expect(noteDraft).toHaveValue('My existing-note draft');
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await page.screenshot({ path: testInfo.outputPath('field-live-reconnected.png'), fullPage: true });

    await mutate('delete', { note });
    await expect(noteHeading).toHaveCount(0);
    await expect(page.getByText('Live song', { exact: true })).toBeVisible();
    expect(page.url()).toBe(selectedUrl); // refresh never pushes or rewrites the reader's URL

    await page.goto(`${base}?q=live`);
    const results = page.getByTestId('field-search-result');
    await expect(results).toHaveCount(2);
    const originalResults = await results.allTextContents();
    await page.waitForLoadState('networkidle');
    const refreshed = page.waitForResponse(
      async (res) =>
        res.url().includes('/field') &&
        (res.request().headers()['x-inertia-partial-data'] || '').split(',').includes('items') &&
        (await res.json()).props.counts?.all === 4
    );
    await mutate('late');
    expect((await (await refreshed).json()).props.counts.all).toBe(4);
    expect(await results.allTextContents()).toEqual(originalResults);
    expect(page.url()).toContain('?q=live');
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
