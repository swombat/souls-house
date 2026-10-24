import { expect, test } from '@playwright/test';

test('an open draft gains and clears cross-account expired logins, including reconnect catch-up', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(90_000);
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `expired-sync-${Date.now()}` },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const mutate = async (accountId, operation) => {
    const result = await request.post('/test/e2e/expired_subscription_fixture', {
      data: { account_id: accountId, operation, email: setup.primary_user.email },
    });
    expect(result.ok()).toBe(true);
    return result.json();
  };
  let socketToReconnect;
  let dropNotifications = false;
  const confirmedAccounts = new Set();
  await page.routeWebSocket('**/cable', (socket) => {
    socketToReconnect = socket;
    const server = socket.connectToServer();
    server.onMessage((message) => {
      const data = JSON.parse(message);
      if (data.type === 'confirm_subscription') {
        const identifier = JSON.parse(data.identifier);
        if (identifier.model === 'Account') confirmedAccounts.add(identifier.id);
      }
      if (!dropNotifications || !data.message) socket.send(message);
    });
  });
  try {
    const { other, hidden } = await mutate(setup.account_id, 'setup');
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const url = `/accounts/${setup.account_param}/chats`;
    await page.goto(url);
    await expect.poll(() => confirmedAccounts.has(other)).toBe(true);
    expect(confirmedAccounts.has(hidden)).toBe(false);
    await page.waitForLoadState('networkidle');
    const originalUrl = page.url();
    const composer = page.getByTestId('message-composer').locator('textarea');
    const draft = 'Keep this unsent draft through subscription updates';
    await composer.fill(draft);
    const menu = page.getByRole('button', { name: 'User account menu' });
    const badge = menu.locator('[aria-label="1 expired subscription"]');
    const noExpiry = async () => {
      // Action Cable's reconnect backoff can itself exceed the default 10s.
      await expect(menu.locator('[aria-label$="expired subscription"]')).toHaveCount(0, { timeout: 20_000 });
      await expect(composer).toHaveValue(draft);
      expect(page.url()).toBe(originalUrl);
    };

    await mutate(hidden, 'expire');
    await mutate(other, 'expire');
    await expect(badge).toBeVisible();
    await expect(composer).toHaveValue(draft);
    await menu.click();
    await expect(page.getByRole('menuitem', { name: /Other Resident · Claude/ })).toBeVisible();
    await expect(page.getByText(/Inaccessible/)).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('expired-menu.png') });
    await page.keyboard.press('Escape');
    await mutate(other, 'reconnect');
    await noExpiry();

    // Miss the only broadcast, then reconnect. No later write rescues either
    // transition: connected() must catch up the count without replacing input.
    for (const operation of ['expire', 'reconnect']) {
      await page.waitForLoadState('networkidle');
      dropNotifications = true;
      await mutate(other, operation);
      socketToReconnect.close({ code: 1012, reason: 'Test reconnect' });
      if (operation === 'expire') await expect(badge).toBeVisible({ timeout: 20_000 });
      else await noExpiry();
      dropNotifications = false;
      await expect(composer).toHaveValue(draft);
      expect(page.url()).toBe(originalUrl);
    }

    await mutate(other, 'expire');
    await expect(badge).toBeVisible();
    await mutate(other, 'api_key');
    await noExpiry();
    await mutate(other, 'expire');
    await expect(badge).toBeVisible();
    await mutate(other, 'retire');
    await noExpiry();
    await mutate(setup.account_id, 'expire');
    await expect(badge).toBeVisible();
    await mutate(setup.account_id, 'remove');
    await noExpiry();
    await page.screenshot({ path: testInfo.outputPath('expired-cleared-draft.png') });

    // Switch through Inertia; the count is still global, not retained from the
    // previous account's navbar, and subsequent changes still arrive.
    await menu.click();
    await page.getByRole('menuitem', { name: /^Account E2E/ }).click();
    await page.getByRole('menuitem', { name: / Team Other$/ }).click();
    // Its only resident was retired above, so the normal account entry sends
    // us to onboarding. The global count must also work on that different page.
    await expect(page).toHaveURL(new RegExp(`/accounts/${other}/residents/new`));
    await expect(menu.locator('[aria-label$="expired subscription"]')).toHaveCount(0);
    await mutate(setup.account_id, 'expire');
    await expect(badge).toBeVisible();
    await mutate(setup.account_id, 'api_key');
    await expect(menu.locator('[aria-label$="expired subscription"]')).toHaveCount(0);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
