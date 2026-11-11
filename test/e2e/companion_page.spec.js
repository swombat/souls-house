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
    await expect(page.getByTestId('companion-linux')).toHaveCount(0);
    await expect(page.getByTestId('companion-linux-link')).toHaveCount(0);
    await expect(page.getByText("Intel Macs and Linux aren't offered yet.")).toBeVisible();

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

test('Linux downloads show beside the Mac one on every OS, each with its checksum', async ({ page, request }) => {
  const base = 'https://github.com/swombat/souls-house-companion/releases/download/early-unsigned-test';
  const amd = `${base}/souls-house-companion-dev-test-linux-amd64.tar.gz`;
  const arm = `${base}/souls-house-companion-dev-test-linux-arm64.tar.gz`;
  const amdSha = 'ab'.repeat(32);
  const armSha = 'cd'.repeat(32);
  const fixture = {
    linux_amd64_url: amd,
    linux_amd64_sha256: amdSha,
    linux_arm64_url: arm,
    linux_arm64_sha256: armSha,
  };
  expect((await request.post('/test/e2e/companion_download_fixture', { data: fixture })).ok()).toBe(true);
  try {
    for (const width of [390, 1280]) {
      await page.setViewportSize({ width, height: 900 });
      await page.goto('/companion');
      // The Mac main button is unchanged; no early Mac build is set in this fixture.
      await expect(page.getByTestId('companion-download-soon').first()).toBeVisible();
      await expect(page.getByTestId('companion-early')).toHaveCount(0);
      const linux = page.getByTestId('companion-linux');
      await expect(linux).toHaveCount(1);
      await expect(page.getByTestId('companion-download-linux-amd64')).toHaveAttribute('href', amd);
      await expect(page.getByTestId('companion-download-linux-arm64')).toHaveAttribute('href', arm);
      await expect(page.getByTestId('companion-linux-amd64-sha256')).toHaveText(amdSha);
      await expect(page.getByTestId('companion-linux-arm64-sha256')).toHaveText(armSha);
      // The compact placement at the foot of the page links up to the downloads.
      await expect(page.getByTestId('companion-linux-link')).toHaveAttribute('href', '/companion#download');
      await expect(page.getByText('or a Linux computer (x86-64 or ARM64)')).toBeVisible();
      await expect(page.getByText('On Linux there is no desktop control')).toBeVisible();
      await expect(page.getByTestId('companion-linux')).toContainText('the house mark in your tray');
      await expect(page.getByText('macOS on Apple Silicon')).toHaveCount(0);
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      if (process.env.FEATURES_SCREENSHOTS) {
        await page.screenshot({
          path: `${process.env.FEATURES_SCREENSHOTS}/companion-linux-${width}.png`,
          fullPage: true,
        });
      }
    }
  } finally {
    await request.post('/test/e2e/companion_download_fixture', { data: {} });
  }
});
