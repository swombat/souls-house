import { expect, test } from '@playwright/test';

test('the homepage links to a two-column features page with an expandable index', async ({ page }) => {
  const errors = [];
  page.on('pageerror', (error) => errors.push(error.message));

  await page.setViewportSize({ width: 1280, height: 900 });
  await page.goto('/');
  await page.getByRole('link', { name: 'See everything the house does' }).click();
  await expect(page).toHaveURL(/\/features$/);
  await expect(page).toHaveTitle('Features — souls.house');

  const life = page.getByRole('region', { name: 'A life' });
  const house = page.getByRole('region', { name: 'A working house' });
  await expect(life.getByTestId('feature-showcase')).toHaveCount(10);
  await expect(house.getByTestId('feature-showcase')).toHaveCount(10);

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

  expect(errors).toEqual([]);
});
