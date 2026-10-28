import { expect, test } from '@playwright/test';

// The public data-model page: the selector moves between areas, each area draws
// its diagram in the browser, and the cards link across areas. The Ruby tests
// prove the props; only a browser proves the drawing.
test('the data model page draws an area and moves between them', async ({ page }, testInfo) => {
  await page.goto('/data-model');
  await expect(page.getByRole('heading', { name: 'The data model.' })).toBeVisible();
  await expect(page.getByRole('heading', { name: 'Accounts and people' })).toBeVisible();
  await expect(page.locator('.diagram svg')).toBeVisible({ timeout: 20_000 });
  await expect(page.locator('article#users')).toBeVisible();

  await page.getByRole('link', { name: /^Billing/ }).click();
  await expect(page).toHaveURL(/\/data-model\/billing$/);
  await expect(page.getByRole('heading', { name: 'Billing' })).toBeVisible();
  await expect(page.locator('.diagram svg')).toBeVisible({ timeout: 20_000 });
  await expect(page.locator('.diagram svg')).toContainText('resident_subscriptions');
  await page.screenshot({ path: testInfo.outputPath('data-model-billing.png'), fullPage: true });

  // A reference into another area links there, at the table.
  const card = page.locator('article#resident_subscriptions');
  await expect(card).toBeVisible();
  await card.getByRole('link', { name: 'agents' }).first().click();
  await expect(page).toHaveURL(/\/data-model\/residents#agents$/);
  await expect(page.getByRole('heading', { name: 'Residents' })).toBeVisible();

  await page.goto('/data-model/kitchen');
  await expect(page.getByText(/not found|doesn.t exist|404/i).first()).toBeVisible();
});
