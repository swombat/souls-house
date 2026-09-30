import { expect, test } from '@playwright/test';

test('resident turn timeout defaults to 30 minutes and persists a 24-hour budget', async ({ page, request }) => {
  const runId = `timeout-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_id}/residents`);
    await page.getByRole('link', { name: 'Edit', exact: true }).first().click();
    const editUrl = page.url();
    await page.getByRole('button', { name: 'Settings', exact: true }).click();
    const timeout = page.getByLabel('Turn timeout (minutes)');
    await expect(timeout).toHaveValue('30');
    await timeout.fill('1440');
    await page.getByRole('button', { name: 'Update Resident', exact: true }).click();
    await expect(page).toHaveURL(editUrl.split('/residents/')[0] + '/residents');
    await page.goto(editUrl);
    await page.getByRole('button', { name: 'Settings', exact: true }).click();
    await expect(page.getByLabel('Turn timeout (minutes)')).toHaveValue('1440');
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
