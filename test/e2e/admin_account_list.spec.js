import { expect, test } from '@playwright/test';

test('mobile admin browses a full-height list, searches, selects and returns; desktop keeps both panes', async ({
  page,
  request,
}) => {
  const runId = `admin-list-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, admin_account_list: true, deprecated: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.admin_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto('/admin/accounts');

    const list = page.getByRole('complementary', { name: 'Account list' });
    const search = list.getByRole('searchbox', { name: 'Search accounts' });
    await expect(list).toBeVisible();
    expect((await list.boundingBox()).height).toBeGreaterThan(650);
    await search.fill(runId);
    const firstAccount = list.getByRole('button', { name: new RegExp(`E2E ${runId} Browse 00`) });
    await firstAccount.scrollIntoViewIfNeeded();
    await expect(firstAccount).toBeInViewport();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: 'test-results/admin-account-list-mobile.png' });
    await firstAccount.click();
    await expect(list).toBeHidden();
    await expect(page.getByRole('heading', { name: `E2E ${runId} Browse 00`, exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Back to accounts' }).click();
    await expect(list).toBeVisible();
    await expect(search).toHaveValue(runId);
    await search.fill('LongAccountName');
    await expect(list.getByRole('button')).toHaveCount(1);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await list.getByRole('button').click();
    await expect(list).toBeHidden();
    await expect(page.getByRole('heading', { level: 1 })).toContainText('LongAccountName');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: 'test-results/admin-account-details-mobile.png' });

    await page.goBack();
    await expect(list).toBeVisible();
    await search.fill('no-such-account-zzzz');
    await expect(list.getByText('No accounts match your search')).toBeVisible();
    await search.fill(runId);
    await page.setViewportSize({ width: 1280, height: 900 });
    await firstAccount.click();
    await expect(list).toBeVisible();
    await expect(page.getByRole('heading', { name: `E2E ${runId} Browse 00`, exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Back to accounts' })).toBeHidden();
    await page.screenshot({ path: 'test-results/admin-account-list-desktop.png' });
    await page.setViewportSize({ width: 320, height: 740 });
    await expect(list).toBeHidden();
    await page.getByRole('button', { name: 'Back to accounts' }).click();
    await expect(list).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
