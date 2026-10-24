import { expect, test } from '@playwright/test';

// The search page renders inside the fixed chat viewport (every chats/* page
// does), so it must scroll itself, and its cards must fit a phone screen.
const LONG_WORD = `Scrollsearch${'x'.repeat(60)}`;

const viewports = [
  { name: 'desktop', width: 1280, height: 720 },
  { name: 'mobile', width: 360, height: 740 },
];

test.describe('message search', () => {
  let setup;

  test.beforeEach(async ({ page, request }) => {
    const runId = `search-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
  });

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  for (const viewport of viewports) {
    test(`results scroll and fit the screen on ${viewport.name}`, async ({ page, request }, testInfo) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      const fixture = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 25, prefix: LONG_WORD },
      });
      expect(fixture.ok()).toBe(true);

      await page.goto(`/accounts/${setup.account_id}/chats/search?q=Scrollsearch`);
      const cards = page.getByTestId('search-results').locator('button');
      await expect(cards).toHaveCount(20);

      // Nothing pokes out sideways.
      const widths = await page.evaluate(() => ({
        doc: document.documentElement.scrollWidth,
        scroller: document.querySelector('[data-testid="search-scroll"]').scrollWidth,
        view: window.innerWidth,
      }));
      expect(widths.doc).toBeLessThanOrEqual(widths.view);
      expect(widths.scroller).toBeLessThanOrEqual(widths.view);
      for (const box of await cards.evaluateAll((els) => els.map((el) => el.getBoundingClientRect().right))) {
        expect(box).toBeLessThanOrEqual(viewport.width);
      }
      await page.screenshot({ path: testInfo.outputPath(`${viewport.name}-top.png`) });

      // The last result and the pagination are reachable by scrolling.
      const scroller = page.getByTestId('search-scroll');
      await scroller.hover();
      await page.mouse.wheel(0, 20000);
      await expect.poll(() => scroller.evaluate((el) => el.scrollTop)).toBeGreaterThan(0);
      await expect(cards.last()).toBeInViewport();
      await expect(page.getByText(/Showing 1 to 20 of 25/)).toBeInViewport();
      const next = page.getByRole('button', { name: /next/i });
      await expect(next).toBeVisible();
      await expect(next).toBeInViewport({ ratio: 1 });
      const nextBox = await next.boundingBox();
      expect(nextBox.x + nextBox.width).toBeLessThanOrEqual(viewport.width);
      await page.screenshot({ path: testInfo.outputPath(`${viewport.name}-bottom.png`) });
    });
  }
});
