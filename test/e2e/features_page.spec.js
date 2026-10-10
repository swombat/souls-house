import { expect, test } from '@playwright/test';

test('the homepage links to a two-column features page with an expandable index', async ({ page }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));

  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/');
  await expect(page.getByTestId('feature-carousel-slide').first()).toBeVisible();
  const changes = page.getByTestId('changelog-carousel-slide');
  expect(await changes.count()).toBeGreaterThan(0);
  expect(await changes.count()).toBeLessThanOrEqual(10);
  await page.getByTestId('see-more-features').click();
  await expect(page).toHaveURL(/\/features$/);
  await expect(page).toHaveTitle('Features — souls.house');

  const life = page.getByRole('region', { name: 'A life' });
  const house = page.getByRole('region', { name: 'A working house' });
  await expect(life.getByTestId('feature-showcase')).toHaveCount(10);
  await expect(house.getByTestId('feature-showcase')).toHaveCount(12);
  await expect(house.getByRole('heading', { name: 'Bring an existing GitHub resident' })).toBeVisible();

  const theirWords = life.getByTestId('feature-showcase').filter({ hasText: 'Their words stay theirs' });
  const download = theirWords.getByTestId('feature-clip-download');
  await expect(download).toHaveAttribute('href', '/feature-clips/their-words.mp4');
  await expect(download).toHaveAttribute('download', 'souls-house-their-words.mp4');
  await expect(download).toHaveCSS('opacity', '0');
  await theirWords.locator('video').hover();
  await expect(download).toHaveCSS('opacity', '1');

  const lifeBox = await life.boundingBox();
  const houseBox = await house.boundingBox();
  expect(houseBox.x).toBeGreaterThan(lifeBox.x + lifeBox.width - 1);
  if (process.env.FEATURES_SCREENSHOTS)
    await page.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/desktop.png`, fullPage: true });

  const dropboxRow = page.getByTestId('feature-index').getByText('Dropbox', { exact: true });
  const detail = page.getByText('Read, write and share files in a connected Dropbox');
  await expect(detail).toBeHidden();
  await dropboxRow.click();
  await expect(detail).toBeVisible();

  await expect(page.getByRole('heading', { name: 'Recently changed' })).toBeVisible();
  await expect(page.getByTestId('changelog-entry').first()).toBeVisible();
  await expect(page.getByText('A voice', { exact: true })).toHaveCount(0);

  await page.setViewportSize({ width: 390, height: 844 });
  const lifeMobile = await life.boundingBox();
  const houseMobile = await house.boundingBox();
  expect(houseMobile.y).toBeGreaterThan(lifeMobile.y + lifeMobile.height - 1);
  if (process.env.FEATURES_SCREENSHOTS)
    await page.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/mobile.png`, fullPage: true });

  await page.getByRole('link', { name: 'See full changelog' }).click();
  await expect(page).toHaveURL(/\/changelog$/);
  await expect(page.getByRole('heading', { level: 1 })).toHaveText('Changelog');
  await expect(page.getByTestId('changelog-entry').first()).toBeVisible();

  const cliEntry = page.getByTestId('changelog-entry').filter({ hasText: 'A command line for souls.house' });
  await expect(cliEntry.getByTestId('changelog-clip')).toHaveAttribute('src', '/changelog-clips/cli.mp4');
  await expect(cliEntry.getByRole('link', { name: 'Download clip' })).toHaveAttribute(
    'download',
    'souls-house-cli.mp4'
  );
  if (process.env.FEATURES_SCREENSHOTS) {
    await page.setViewportSize({ width: 1280, height: 900 });
    await cliEntry.scrollIntoViewIfNeeded();
    await page.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/changelog.png` });
  }

  expect(errors).toEqual([]);
});

test('logged-out visitors get Features as a top-level navbar link, on desktop and in the mobile menu', async ({
  page,
}) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/changelog');
  const navLink = page.locator('nav').first().getByRole('link', { name: 'Features', exact: true });
  await expect(navLink).toBeVisible();
  if (process.env.FEATURES_SCREENSHOTS)
    await page.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/nav-desktop.png` });
  await navLink.click();
  await expect(page).toHaveURL(/\/features$/);

  await page.setViewportSize({ width: 390, height: 844 });
  await expect(navLink).toBeHidden();
  await page.getByRole('button', { name: /Not Logged In/ }).click();
  const menuItem = page.getByRole('menuitem', { name: 'Features', exact: true });
  await expect(menuItem).toBeVisible();
  if (process.env.FEATURES_SCREENSHOTS)
    await page.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/nav-mobile.png` });
});

test('the soul seed card plays its rendered clip, muted and looping, with a poster frame', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/features');
  const card = page.getByTestId('feature-showcase').filter({ hasText: 'A soul seed, not a system prompt' });
  const video = card.locator('video');
  await expect(video).toHaveAttribute('src', '/feature-clips/soul-seed.mp4');
  await expect(video).toHaveAttribute('poster', '/feature-clips/soul-seed.jpg');
  expect(await video.evaluate((el) => el.muted && el.loop)).toBe(true);
  const poster = await page.request.get('/feature-clips/soul-seed.jpg');
  expect(poster.ok()).toBe(true);
  const clip = await page.request.get('/feature-clips/soul-seed.mp4');
  expect(clip.ok()).toBe(true);
  expect(clip.headers()['content-type']).toContain('video/mp4');
  if (process.env.FEATURES_SCREENSHOTS) {
    await video.evaluate((el) => {
      el.pause();
      el.currentTime = 11;
    });
    await page.waitForTimeout(300);
    await card.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/soul-seed-card.png` });
  }
});

test('every featured clip and its poster are served as files', async ({ page }) => {
  await page.goto('/features');
  const sources = await page
    .locator('[data-testid=feature-showcase] video')
    .evaluateAll((videos) => videos.map((video) => [video.getAttribute('src'), video.getAttribute('poster')]));
  expect(sources.map(([src]) => src).sort()).toEqual(
    [
      'attachments',
      'backups',
      'computer',
      'github-resident',
      'github',
      'google',
      'guests',
      'heartbeats',
      'journals',
      'models',
      'open-source',
      'portability',
      'recall',
      'rhythms',
      'rooms',
      'soul-seed',
      'stones',
      'subscriptions',
      'tailscale',
      'telegram',
      'their-words',
    ].map((name) => `/feature-clips/${name}.mp4`)
  );
  for (const [src, poster] of sources) {
    const clip = await page.request.get(src);
    expect(clip.ok(), src).toBe(true);
    expect(clip.headers()['content-type']).toContain('video/mp4');
    expect((await page.request.get(poster)).ok(), poster).toBe(true);
  }
  if (process.env.FEATURES_SCREENSHOTS) {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.screenshot({ path: `${process.env.FEATURES_SCREENSHOTS}/clips-desktop.png`, fullPage: true });
  }
});
