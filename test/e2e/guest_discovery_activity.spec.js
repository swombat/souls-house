import { expect, test } from '@playwright/test';

test('other-home candidate arrivals and reconnect refresh only discovery and preserve selection', async ({ page, request }) => {
  test.setTimeout(120_000);
  const runId = `guest-discovery-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const mutate = async (operation) => {
    const result = await request.post('/test/e2e/guest_directory_fixture', {
      data: { account_id: setup.account_id, operation },
    });
    expect(result.ok()).toBe(true);
    return operation === 'setup' ? result.json() : null;
  };
  const fixture = await mutate('setup');
  let socket;
  let drop = false;
  let confirmations = 0;
  await page.routeWebSocket('**/cable', (cable) => {
    socket = cable;
    cable.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      const model = message.identifier && JSON.parse(message.identifier).model;
      if (message.type === 'confirm_subscription' && model === 'GuestDiscovery') confirmations++;
      if (!(drop && model === 'GuestDiscovery' && message.message)) cable.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('guest_candidates')) reloads.push(props);
  });
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/agents`);
    await expect.poll(() => confirmations).toBeGreaterThan(0);
    await expect.poll(() => reloads.length).toBeGreaterThan(0);
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(700);
    const select = page.getByLabel('Resident from another of your accounts');
    await select.selectOption(fixture.spare);
    await mutate('candidate_arrive');
    await expect(select.locator('option').filter({ hasText: 'New candidate' })).toHaveCount(1);
    await expect(select).toHaveValue(fixture.spare);
    await page.waitForLoadState('networkidle');
    // Home Account's pre-existing broadcasts also refresh two navbar props.
    expect(reloads.at(-1)).toContain('guest_candidates');
    expect(reloads.at(-1)).not.toContain('agents');
    expect(reloads.at(-1)).not.toContain('guest_memberships');
    const quiet = reloads.length;
    await mutate('candidate_bookkeeping');
    await page.waitForTimeout(900);
    expect(reloads).toHaveLength(quiet);

    drop = true;
    await mutate('candidate_offline');
    await expect(select.locator('option').filter({ hasText: 'New candidate' })).toHaveCount(1);
    const beforeReconnect = confirmations;
    socket.close({ code: 1012, reason: 'Synthetic discovery reconnect' });
    await expect.poll(() => confirmations, { timeout: 20_000 }).toBeGreaterThan(beforeReconnect);
    await expect(select.locator('option').filter({ hasText: 'New candidate' })).toHaveCount(0);
    drop = false;
    await expect(select).toHaveValue(fixture.spare);
    await mutate('candidate_return');
    await expect(select.locator('option').filter({ hasText: 'New candidate' })).toHaveCount(1);
    await expect(select).toHaveValue(fixture.spare);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
