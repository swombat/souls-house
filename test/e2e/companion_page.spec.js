import { expect, test } from '@playwright/test';

// The second test changes a site-wide setting the first one asserts is blank.
test.describe.configure({ mode: 'serial' });

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
    await expect(page.getByTestId('companion-early')).toHaveCount(0);

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

test('an early unsigned build is offered under coming soon, with its notice and checksum', async ({
  page,
  request,
}) => {
  const sha = 'ab'.repeat(32);
  const url = 'https://github.com/swombat/souls-house-companion/releases/download/early-unsigned-test/x.zip';
  expect(
    (await request.post('/test/e2e/companion_download_fixture', { data: { early_url: url, early_sha256: sha } })).ok()
  ).toBe(true);
  try {
    for (const width of [390, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto('/companion');
      await expect(page.getByTestId('companion-download-soon').first()).toBeVisible();
      await expect(page.getByTestId('companion-download')).toHaveCount(0);
      const early = page.getByTestId('companion-early');
      await expect(early).toHaveCount(1);
      await expect(early).toContainText('was blocked to protect your Mac');
      await expect(early).toContainText('Open Anyway');
      await expect(early).toContainText('each update asks for the Accessibility permission again');
      await expect(page.getByTestId('companion-download-early')).toHaveAttribute('href', url);
      await expect(page.getByTestId('companion-early-sha256')).toHaveText(sha);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      if (process.env.FEATURES_SCREENSHOTS) {
        await page.screenshot({
          path: `${process.env.FEATURES_SCREENSHOTS}/companion-early-${width}.png`,
          fullPage: true,
        });
      }
    }
  } finally {
    await request.post('/test/e2e/companion_download_fixture', { data: {} });
  }
});
