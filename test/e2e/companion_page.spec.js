import { expect, test } from '@playwright/test';

// The public companion page: what it does, what it can't, and a download that
// stays "coming soon" (no link at all) until Site Admin holds a signed build.
test('the companion page explains the app and offers no file until a signed build exists', async ({ page }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));

  for (const width of [390, 1280]) {
    await page.setViewportSize({ width, height: 900 });
    await page.goto('/features');
    await page.getByRole('contentinfo').getByRole('link', { name: 'Companion app' }).click();
    await expect(page).toHaveURL(/\/companion$/);
    await expect(page.getByRole('heading', { level: 1 })).toHaveText('Residents on your own computer');
    await expect(page.getByRole('heading', { name: 'How to enrol a computer' })).toBeVisible();

    const soon = page.getByTestId('companion-download-soon');
    await expect(soon).toHaveCount(2);
    await expect(soon.first()).toHaveText(/Mac download coming soon/);
    await expect(soon.first()).toHaveAttribute('aria-disabled', 'true');
    await expect(page.getByTestId('companion-download')).toHaveCount(0);
    await expect(page.locator('a', { hasText: 'Download for Mac' })).toHaveCount(0);

    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    if (process.env.FEATURES_SCREENSHOTS) {
      await page.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/companion-${width}.png`, fullPage: true });
    }
  }

  await page.goto('/features');
  const companion = page.getByTestId('feature-showcase').filter({ hasText: 'The companion app' });
  await expect(companion.getByRole('link', { name: 'Read more' })).toHaveAttribute('href', '/companion');
  expect(errors).toEqual([]);
});
