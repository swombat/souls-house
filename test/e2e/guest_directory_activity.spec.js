import { expect, test } from '@playwright/test';

test.use({ actionTimeout: 10_000 });

test('guest arrivals and removal reach both open directories while drafts survive', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `guest-directory-${Date.now()}`;
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
  let confirmed = false;
  await page.routeWebSocket('**/cable', (cable) => {
    socket = cable;
    cable.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.type === 'confirm_subscription' && JSON.parse(message.identifier).model === 'GuestDirectory')
        confirmed = true;
      if (!drop || !message.message) cable.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('guest_memberships')) reloads.push(props);
  });
  let home;
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/agents`);
    home = await page.context().newPage();
    await home.goto(`/accounts/${fixture.home}/agents`);
    await expect.poll(() => confirmed).toBe(true);
    await expect.poll(() => reloads.length).toBeGreaterThan(0);
    await page.waitForLoadState('networkidle');
    const select = page.getByLabel('Resident from another of your accounts');
    await select.selectOption(fixture.spare);
    const beforeJoin = reloads.length;
    await mutate('join');
    await expect(page.getByTestId('guest-residents')).toContainText('Live visitor');
    await expect(home.getByTestId('away-residents')).toContainText('Live visitor');
    await expect(select).toHaveValue(fixture.spare);
    await page.waitForLoadState('networkidle');
    expect(reloads.length - beforeJoin).toBeLessThanOrEqual(2);
    expect([...reloads.at(-1)].sort()).toEqual(
      ['guest_memberships', 'away_memberships', 'guest_candidates', 'can_end_guest_memberships'].sort()
    );

    // Directory refresh must not remount an unrelated upgrade dialog.
    await page
      .getByTitle("Change this resident's model and preserve a historical, unavailable predecessor record")
      .first()
      .click();
    const draft = page.getByLabel('Predecessor name');
    await draft.fill('Unfinished predecessor');
    drop = true;
    await mutate('leave');
    await expect(home.getByTestId('away-residents')).toHaveCount(0);
    socket.close({ code: 1012, reason: 'Synthetic guest directory reconnect' });
    await expect(page.getByTestId('guest-residents')).toHaveCount(0, { timeout: 20_000 });
    drop = false;
    await expect(draft).toHaveValue('Unfinished predecessor');
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(select).toHaveValue(fixture.spare);

    await mutate('join');
    await expect(page.getByTestId('guest-residents')).toBeVisible();
    await mutate('delete');
    await expect(page.getByTestId('guest-residents')).toHaveCount(0);
    await expect(home.getByTestId('away-residents')).toHaveCount(0);
    await expect(select).toHaveValue(fixture.spare);
    await page.screenshot({ path: testInfo.outputPath('guest-directory-live.png'), fullPage: true });
  } finally {
    await home?.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
