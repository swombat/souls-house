import { expect, test } from '@playwright/test';

test('admin can inspect account usage, settings and empty states on desktop and mobile', async ({ page, request }) => {
  const runId = `admin-usage-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();

  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.admin_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/admin/accounts?account_id=${setup.account_id}`);

    const overview = page.getByRole('region', { name: 'Account usage overview' });
    await expect(overview.getByRole('heading', { name: 'Residents (4)', exact: true })).toBeVisible();
    await expect(overview.getByRole('heading', { name: 'E2E Researcher', exact: true })).toBeVisible();
    await expect(overview.getByRole('heading', { name: 'Integrations & AI access' })).toBeVisible();
    await expect(overview.getByRole('heading', { name: 'Last 10 runtime sessions' })).toBeVisible();
    await expect(overview.getByText('No conversations yet.')).toBeVisible();
    await expect(overview.getByRole('button', { name: 'Measure storage' })).toBeDisabled();
    await expect(overview.getByText('Deprecated · inline', { exact: true })).toHaveCount(4);
    await expect(overview.locator('article.grayscale')).toHaveCount(4);
    await expect(overview.getByText('external', { exact: true })).toHaveCount(0);
    await expect(overview.getByText(/^API · /)).toHaveCount(4);
    const logos = overview.locator('img[src^="/model-providers/"]');
    await expect(logos).toHaveCount(4);
    await expect.poll(() => logos.evaluateAll((images) => images.every((image) => image.complete && image.naturalWidth > 0))).toBe(true);

    await overview.getByLabel('Activity metric').selectOption('conversations');
    await expect(overview.getByRole('img', { name: /conversations over/ })).toBeVisible();
    await overview.locator('summary').filter({ hasText: 'Settings, integrations' }).first().click();
    await expect(overview.getByText('Telegram: Not connected').first()).toBeVisible();

    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await overview.getByRole('button', { name: 'Refresh overview' }).click();
    await expect(overview.getByRole('heading', { name: 'Residents (4)', exact: true })).toBeVisible();

    await page.goto(`/admin/accounts?account_id=${setup.empty_account_id}`);
    await expect(overview.getByText('No residents have been created in this account.')).toBeVisible();
    await expect(overview.getByText('No activity in this period.')).toBeVisible();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
