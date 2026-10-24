import { expect, test } from '@playwright/test';

test('costs discover a new home resident and recover corrected usage without health-check report reloads', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `account-cost-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const mutate = async (operation) => {
    const result = await request.post('/test/e2e/account_cost_fixture', {
      data: { account_id: setup.account_id, operation },
    });
    expect(result.ok()).toBe(true);
  };
  const confirmed = new Set();
  const subscriptions = [];
  const hints = [];
  let socket;
  let drop = false;
  await page.routeWebSocket('**/cable', (cable) => {
    socket = cable;
    cable.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.identifier) {
        const identifier = JSON.parse(message.identifier);
        if (message.type === 'confirm_subscription') {
          subscriptions.push(identifier.model);
          confirmed.add(identifier.model);
        }
        if (message.message && ['HomeResidentRoster', 'AccountCostActivity'].includes(identifier.model))
          hints.push(message.message);
      }
      if (!drop || !message.message) cable.send(raw);
    });
  });
  const partials = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('cost_report')) partials.push(props);
  });
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/costs`);
    await expect.poll(() => confirmed.has('HomeResidentRoster') && confirmed.has('AccountCostActivity')).toBe(true);
    await expect(page.getByText('No estimated interaction costs are available yet.')).toBeVisible();
    await expect.poll(() => partials.length).toBeGreaterThan(0);
    await page.waitForLoadState('networkidle');

    const beforeCreate = partials.length;
    await mutate('create');
    await expect.poll(() => partials.length).toBeGreaterThan(beforeCreate);
    expect(partials.at(-1)).toEqual(expect.arrayContaining(['agents', 'cost_report']));
    await page.waitForLoadState('networkidle');
    const beforeFinish = partials.length;
    await mutate('finish');
    await expect(page.locator('thead th').filter({ hasText: /^Live cost resident$/ })).toBeVisible();
    await expect(page.getByText('≈$61.00').first()).toBeVisible();
    expect(partials.length - beforeFinish).toBeLessThanOrEqual(2);
    expect(partials.at(-1)).toEqual(['cost_report']);
    expect(subscriptions).not.toContain('Agent');
    expect(hints.length).toBeGreaterThanOrEqual(2);
    for (const hint of hints) expect(hint).toEqual({ action: 'refresh' });

    await page.waitForLoadState('networkidle');
    const beforeHealth = partials.length;
    await mutate('health');
    await page.waitForTimeout(900); // negative assertion beyond the shared debounce
    expect(partials).toHaveLength(beforeHealth);
    const total = page
      .getByText('Estimated API-key account cost to date', { exact: true })
      .locator('..')
      .locator('.text-2xl');
    const previous = await total.textContent();
    drop = true;
    await mutate('correct_usage');
    socket.close({ code: 1012, reason: 'Synthetic cost-marker reconnect' });
    await expect(total).not.toHaveText(previous, { timeout: 20_000 });
    drop = false;
    await expect(page.locator('thead th').filter({ hasText: /^Live cost resident$/ })).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('account-cost-live.png'), fullPage: true });
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
