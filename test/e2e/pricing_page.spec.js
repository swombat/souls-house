import { test, expect } from '@playwright/test';

// /pricing is public and unlinked. Screenshots are for design review.
test.describe('pricing page', () => {
  for (const [name, viewport] of [
    ['desktop', { width: 1440, height: 900 }],
    ['mobile', { width: 390, height: 844 }],
  ]) {
    test(`renders the plans on ${name}`, async ({ page }, testInfo) => {
      await page.setViewportSize(viewport);
      await page.goto('/pricing');
      await expect(page.getByRole('heading', { name: 'A home for someone, by the month.' })).toBeVisible();
      for (const plan of ['Companions', 'Partners', 'Colleagues']) {
        await expect(page.getByRole('heading', { name: plan, exact: true })).toBeVisible();
      }
      await expect(page.getByRole('heading', { name: 'Residents, by size' })).toBeVisible();
      const sizes = page.getByTestId('pricing-sizes');
      for (const size of ['Small', 'Medium', 'Large']) {
        await expect(sizes.getByRole('heading', { name: size, exact: true })).toBeVisible();
      }
      await expect(page.getByRole('heading', { name: 'We never delete a resident.' })).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath(`pricing-${name}.png`), fullPage: true });
    });
  }

  // Daniel, 11 Nov (YGBNNJ): on a phone the sizes table ran off the right
  // edge and cut the prices ("$9.9"). Each size is a card now; at 360 px
  // nothing in the section scrolls sideways and every price is whole.
  for (const viewport of [
    { width: 360, height: 800 },
    { width: 1280, height: 900 },
  ]) {
    test(`residents by size fit a ${viewport.width} px screen, every price whole`, async ({ page }, testInfo) => {
      await page.setViewportSize(viewport);
      await page.goto('/pricing');
      const sizes = page.getByTestId('pricing-sizes');
      await sizes.scrollIntoViewIfNeeded();
      const overflow = await sizes.evaluate((section) =>
        [section, ...section.querySelectorAll('*')]
          .filter((el) => el.scrollWidth > el.clientWidth + 1 && getComputedStyle(el).overflowX !== 'visible')
          .map((el) => el.tagName)
      );
      expect(overflow).toEqual([]);
      const width = await sizes.evaluate((section) => [section.scrollWidth, section.clientWidth]);
      expect(width[0]).toBeLessThanOrEqual(width[1]);
      const prices = sizes.locator('[data-size] [data-size-price]');
      await expect(prices).toHaveCount(3);
      for (const box of await prices.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().toJSON()))) {
        expect(box.left).toBeGreaterThanOrEqual(0);
        expect(box.right).toBeLessThanOrEqual(viewport.width);
      }
      await sizes.screenshot({ path: testInfo.outputPath(`pricing-sizes-${viewport.width}.png`) });
    });
  }
});
