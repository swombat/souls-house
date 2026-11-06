import { expect, test } from '@playwright/experimental-ct-svelte';
import TelegramUnlinkedArrivals from '../../app/frontend/lib/components/agents/telegram-unlinked-arrivals.svelte';

for (const width of [390, 1100]) {
  test(`unlinked arrival warning is readable at ${width}px`, async ({ mount, page }) => {
    await page.setViewportSize({ width, height: 700 });
    const component = await mount(TelegramUnlinkedArrivals, {
      props: { count: 17, lastReceivedAt: '2026-11-06T11:00:00Z' },
    });
    await expect(component.getByRole('heading', { name: 'Messages from unlinked chats' })).toBeVisible();
    await expect(component).toContainText('17 messages received');
    await expect(component).toContainText('not a waiting inbox');
    await expect(component).toContainText('cannot be recovered');
    await expect(component.locator('time')).toHaveAttribute('datetime', '2026-11-06T11:00:00Z');
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await component.screenshot({ path: `tmp/telegram-unlinked-${width}.png` });
  });
}
