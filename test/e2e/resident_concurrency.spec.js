import { expect, test } from '@playwright/test';

test('admin can inspect and pause resident admission without enabling the rollout', async ({ page, request }) => {
  const runId = `concurrency-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  let previous;
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.admin_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto('/admin/resident_turns');
    await expect(page.getByRole('heading', { name: 'Resident concurrency' })).toBeVisible();
    const limit = page.getByLabel('Turn limit (0 pauses admission)');
    previous = await limit.inputValue();
    await limit.fill('0');
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(limit).toHaveValue('0');
    await page.reload();
    await expect(limit).toHaveValue('0');
    await expect(page.getByText(/disabled \(legacy synchronous dispatch\)/)).toBeVisible();
    await page.screenshot({ path: 'test-results/resident-concurrency-desktop.png', fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(page.getByRole('button', { name: 'Save', exact: true })).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: 'test-results/resident-concurrency-mobile.png', fullPage: true });
  } finally {
    if (previous !== undefined) {
      await page.goto('/admin/resident_turns');
      await page.getByLabel('Turn limit (0 pauses admission)').fill(previous);
      await page.getByRole('button', { name: 'Save', exact: true }).click();
    }
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
