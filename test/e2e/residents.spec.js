import { expect, test } from '@playwright/test';

test('resident cards show compact charts, quotas and permissions at desktop and mobile widths', async ({
  page,
  request,
}) => {
  const runId = `residents-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, resident_dashboard: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.route('**/provider_subscription_usage', (route) =>
      route.fulfill({
        json: {
          status: 'available',
          windows: [
            { label: 'Session', remaining_percent: 40, resets_at: new Date(Date.now() + 2.5 * 3600000).toISOString() },
            { label: 'Weekly', remaining_percent: 60, resets_at: new Date(Date.now() + 3.5 * 86400000).toISOString() },
          ],
        },
      })
    );
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_id}/agents`);
    await expect(page).toHaveURL(/\/residents$/);
    await expect(page.getByText('E2E Researcher', { exact: true })).toBeVisible();
    await expect(page.getByText('120% predicted')).toHaveClass(/text-red-600/);
    await expect(page.getByText('80% predicted')).toHaveClass(/text-amber-700/);
    await expect(page.getByRole('meter')).toHaveCount(2);
    await expect(page.getByText('1.0 GiB')).toBeVisible();
    await expect(page.getByRole('img', { name: /Sessions over/ })).toHaveCount(4);
    await expect(page.getByRole('img', { name: /Messages over/ })).toHaveCount(4);
    await expect(page.getByTitle('example/dashboard · disabled')).toHaveCount(3);
    await expect(page.getByText(/You are E2E/)).toHaveCount(0);
    await expect(page.getByText('Model:', { exact: true })).toHaveCount(0);
    await page.screenshot({ path: 'test-results/residents-desktop.png', fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: 'test-results/residents-mobile.png', fullPage: true });
    await page.getByRole('link', { name: 'Edit', exact: true }).first().click();
    await expect(page).toHaveURL(/\/residents\/[^/]+\/edit$/);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
