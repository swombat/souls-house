import { expect, test } from '@playwright/test';

test('account services leads to account-scoped device controls and separate recovery', async ({ page, request }) => {
  const runId = `device-streams-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();

  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/services`);
    await expect(page.getByRole('heading', { name: 'Device integrations' })).toBeVisible();
    await page.screenshot({ path: 'test-results/device-integrations-desktop.png', fullPage: true });
    await page.getByRole('link', { name: 'Manage your device streams' }).click();
    await expect(page).toHaveURL(`/accounts/${setup.account_param}/device_streams`);
    await expect(page.locator('select[name=account_id]')).toHaveCount(0);
    await page.getByLabel('Stream name').fill('Synthetic H10');
    await page.getByRole('button', { name: 'Create disabled stream' }).click();
    await expect(page.getByRole('heading', { name: 'Synthetic H10' })).toBeVisible();
    await expect(page).toHaveURL(new RegExp(`/accounts/${setup.account_param}/device_streams/[a-f0-9]+$`));
    await expect(page.getByLabel('Enable device ingestion')).not.toBeChecked();
    await expect(page.getByLabel('E2E Researcher (agent)', { exact: true })).toBeVisible();
    await page.getByLabel('E2E Researcher (agent)', { exact: true }).check();
    await page.getByRole('button', { name: 'Save readers and ingestion choice' }).click();
    await expect(page.getByLabel('E2E Researcher (agent)', { exact: true })).toBeChecked();
    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: 'test-results/device-stream-controls-mobile.png', fullPage: true });
    await page.goto('/device_streams');
    await page.getByRole('link', { name: 'Synthetic H10' }).click();
    await expect(page.getByRole('button', { name: 'Create append-only device credential' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Save readers and ingestion choice' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Permanently erase all data and close stream' })).toBeVisible();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
