import { expect, test } from '@playwright/test';

test('already-open rhythm readers update, reconnect and preserve a pause draft', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `rhythms-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
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
      if (data.type === 'confirm_subscription' && JSON.parse(data.identifier).model === 'RhythmActivity')
        confirmed = true;
      if (!drop || !data.message) socket.send(raw);
    });
  });
  const editor = await page.context().newPage();
  try {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}/rhythms`;
    await page.goto(base);
    await expect.poll(() => confirmed).toBe(true);
    await expect(page.getByRole('heading', { name: 'What would you like to come back to?' })).toBeVisible();
    await editor.goto(`${base}/new`);
    await editor.getByLabel('Conversation title', { exact: true }).fill('Live invitation');
    await editor.getByLabel('Opening message', { exact: true }).fill('Synthetic invitation');
    await editor.getByRole('button', { name: 'E2E Researcher', exact: true }).click();
    await editor.getByRole('button', { name: 'Create rhythm', exact: true }).click();
    await expect(editor.getByRole('heading', { name: 'Live invitation', exact: true })).toBeVisible();
    const detail = editor.url();
    await expect(page.getByRole('link', { name: /Live invitation/ }).first()).toBeVisible();
    await page.goto(detail);
    await page.getByRole('button', { name: 'Pause', exact: true }).click();
    await page.getByPlaceholder('Reason (optional)').fill('Unsubmitted pause draft');
    await editor.getByRole('button', { name: /Start one now/ }).click();
    await expect(page.getByText('started by hand', { exact: true })).toBeVisible();
    await expect(page.getByPlaceholder('Reason (optional)')).toHaveValue('Unsubmitted pause draft');
    await editor.getByRole('button', { name: 'Pause', exact: true }).click();
    await editor.getByPlaceholder('Reason (optional)').fill('Paused elsewhere');
    await editor.getByRole('button', { name: 'Pause', exact: true }).click();
    await expect(page.getByText('Paused elsewhere', { exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: /Start one now/ })).toBeDisabled();
    await expect(page.getByPlaceholder('Reason (optional)')).toHaveValue('Unsubmitted pause draft');
    await page.screenshot({ path: testInfo.outputPath('rhythm-live-draft.png'), fullPage: true });
    await page.goto(base);
    await page.waitForLoadState('networkidle');
    drop = true;
    await editor.getByRole('link', { name: 'Edit', exact: true }).click();
    await editor.getByLabel('Conversation title', { exact: true }).fill('Renamed while disconnected');
    await editor.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect(editor.getByRole('heading', { name: 'Renamed while disconnected', exact: true })).toBeVisible();
    cable.close({ code: 1012, reason: 'Synthetic rhythm reconnect' });
    await expect(page.getByRole('link', { name: /Renamed while disconnected/ }).first()).toBeVisible({
      timeout: 20_000,
    });
    drop = false;
    await page.goto(detail);
    editor.on('dialog', (dialog) => dialog.accept());
    await editor.getByRole('button', { name: 'Delete rhythm', exact: true }).click();
    await expect(page.getByRole('heading', { name: 'This rhythm has been deleted' })).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('rhythm-live-deleted.png'), fullPage: true });
  } finally {
    await editor.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
