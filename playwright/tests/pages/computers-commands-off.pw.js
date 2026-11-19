import { expect, test } from '@playwright/experimental-ct-svelte';
import ComputersHarness from '../../ComputersHarness.svelte';

const mac = {
  id: 'dev1',
  name: "Daniel's Mac",
  paused: false,
  connected: true,
  commands_off_locally: true,
  residents: [{ id: 'lume', name: 'Lume', execute: true, desktop: false, volumes: [] }],
};

for (const width of [390, 1100]) {
  test(`the Mac's commands-off note is readable at ${width}px`, async ({ mount, page }) => {
    await page.setViewportSize({ width, height: 900 });
    const component = await mount(ComputersHarness, {
      props: { account: { id: 'acct', name: 'Home' }, devices: [mac] },
    });
    const note = component.getByTestId('commands-off-locally');
    await expect(note).toBeVisible();
    await expect(note).toHaveText(
      "This Mac hasn't allowed commands yet. Turn on “Let residents run commands on this Mac” in its menu bar."
    );
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
    await page.screenshot({ path: `tmp/computers-commands-off-${width}.png`, fullPage: true });
  });
}
