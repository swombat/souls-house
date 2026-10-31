import { expect, test } from '@playwright/test';

test('FreeAgent explains write-capable user permissions before authorisation', async ({ page, request }, testInfo) => {
  const runId = `freeagent-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, resident_dashboard: true, integrations: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/accounts/${setup.account_param}/integrations?connect=freeagent`);
    await expect(page.getByRole('heading', { name: 'FreeAgent', exact: true })).toBeVisible();
    await expect(page.getByText(/FreeAgent has no read-only OAuth scope/)).toBeVisible();
    await expect(page.getByText(/within that user's\s+permission level/)).toBeVisible();
    await expect(page.getByRole('button', { name: 'Connect FreeAgent', exact: true })).toBeVisible();
    await expect(page.getByRole('combobox')).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('freeagent-desktop.png'), fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(page.getByRole('button', { name: 'Connect FreeAgent', exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath('freeagent-mobile.png'), fullPage: true });
    // Do not click through to a live provider in browser tests.
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
