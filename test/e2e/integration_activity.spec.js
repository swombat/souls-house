import { expect, test } from '@playwright/test';

test('open integration pages and resident tabs update without losing a connect draft', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `integration-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, resident_dashboard: true, integrations: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  let cable;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (socket) => {
    cable = socket;
    const server = socket.connectToServer();
    server.onMessage((raw) => {
      const data = JSON.parse(raw);
      if (data.type === 'confirm_subscription' && JSON.parse(data.identifier).model === 'IntegrationStatus')
        confirmed = true;
      if (!drop || !data.message) socket.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    if ((req.headers()['x-inertia-partial-data'] || '').split(',').includes('connections'))
      reloads.push(req.headers()['x-inertia-partial-data']);
  });
  const editor = await page.context().newPage();
  const resident = await page.context().newPage();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}`;
    await page.goto(`${base}/integrations`);
    await expect.poll(() => confirmed).toBe(true);
    const readerRow = page.getByRole('article').filter({ hasText: 'Team files' });
    await readerRow.getByRole('button', { name: 'Show details for Team files', exact: true }).click();
    await editor.goto(`${base}/integrations`);
    const editorRow = editor.getByRole('article').filter({ hasText: 'Team files' });
    await editorRow.getByRole('button', { name: 'Show details for Team files', exact: true }).click();
    const name = setup.agents[0].name;
    await resident.goto(`${base}/residents/${setup.agents[0].id}/edit?tab=integrations`);
    await editorRow.getByRole('switch', { name: `Enable Team files for ${name}`, exact: true }).click();
    await expect(readerRow.getByRole('switch', { name: `Disable Team files for ${name}`, exact: true })).toBeChecked();
    await expect(readerRow.getByRole('button', { name: 'Hide details for Team files', exact: true })).toBeVisible();
    await expect(
      resident
        .locator('.p-5')
        .filter({ has: resident.getByRole('heading', { name: 'Team files', exact: true }) })
        .getByRole('button', { name: 'Disable', exact: true })
    ).toBeVisible();
    await page.waitForLoadState('networkidle');
    const beforeChat = reloads.length;
    expect(
      (
        await request.post('/test/e2e/field_activity_fixture', {
          data: { account_id: setup.account_id, operation: 'chat' },
        })
      ).ok()
    ).toBe(true);
    await page.waitForTimeout(900); // negative assertion beyond the shared debounce
    expect(reloads).toHaveLength(beforeChat);

    // A sole missed event is recovered on reconnect without navigating.
    drop = true;
    await editorRow.getByLabel('Turn on for new residents automatically').check();
    await expect(editorRow.getByLabel('Turn on for new residents automatically')).toBeChecked();
    cable.close({ code: 1012, reason: 'Synthetic integration reconnect' });
    await expect(readerRow.getByLabel('Turn on for new residents automatically')).toBeChecked({
      timeout: 20_000,
    });
    drop = false;
    await page.screenshot({ path: testInfo.outputPath('integrations-live.png'), fullPage: true });

    await page.goto(`${base}/integrations?connect=google_workspace`);
    await page.getByRole('radio', { name: /The whole account/ }).check();
    const before = reloads.length;
    await editorRow.getByRole('switch', { name: `Disable Team files for ${name}`, exact: true }).click();
    await expect.poll(() => reloads.length).toBeGreaterThan(before);
    await expect(page.getByRole('radio', { name: /The whole account/ })).toBeChecked();
    await expect(page).toHaveURL(/connect=google_workspace/);
    expect(reloads.at(-1).split(',')).not.toContain('focused_service');
  } finally {
    await editor.close();
    await resident.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
