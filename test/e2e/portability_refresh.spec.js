import { expect, test } from '@playwright/test';

test('export status refresh is explicit and preserves the resident draft', async ({ page, request }, testInfo) => {
  const runId = `export-refresh-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const statusRequests = [];
  page.on('request', (req) => {
    if ((req.headers()['x-inertia-partial-data'] || '').split(',').includes('portability')) statusRequests.push(req);
  });
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(setup.agents[0].edit_url);
    await page.waitForLoadState('networkidle');
    const name = page.getByLabel('Display name', { exact: true });
    await name.fill('Unsubmitted resident draft');
    await page.getByRole('button', { name: 'Export / Import', exact: true }).click();
    await expect(page.getByText('Export readiness is a snapshot.', { exact: false })).toBeVisible();
    expect(statusRequests).toHaveLength(0);
    await page.getByRole('button', { name: 'Refresh export status', exact: true }).click();
    await expect.poll(() => statusRequests.length).toBe(1);
    await expect(page.getByRole('button', { name: 'Refresh export status', exact: true })).toBeEnabled();
    expect(statusRequests[0].headers()['x-inertia-partial-data']).toBe('portability');
    await page.getByRole('button', { name: 'Appearance', exact: true }).click();
    await expect(name).toHaveValue('Unsubmitted resident draft');
    await page.screenshot({ path: testInfo.outputPath('export-status-draft.png') });
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
