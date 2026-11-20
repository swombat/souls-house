import { expect, test } from '@playwright/experimental-ct-svelte';
import ComputersHarness from '../../ComputersHarness.svelte';

// Daniel, YMamQY: the buttons above the computers looked "a bit weird". The
// compact Mac download sat in its own column, higher than Add a computer,
// with the Linux link hanging underneath. They now share one row.
const mac = { id: 'dev1', name: "Paulina's Mac", paused: false, connected: true, residents: [] };
const site_settings = {
  companion_mac_download_url: 'https://example.test/souls.house.dmg',
  companion_linux_amd64_download_url: 'https://example.test/linux.tgz',
  companion_linux_amd64_download_sha256: 'a'.repeat(64),
};

test('Add a computer, Download for Mac and the Linux link sit in one row', async ({ mount, page }) => {
  await page.setViewportSize({ width: 1100, height: 700 });
  const component = await mount(ComputersHarness, {
    props: { account: { id: 'acct', name: 'Home' }, devices: [mac], can_add: true, site_settings },
  });
  const centre = async (locator) => {
    const box = await locator.boundingBox();
    return box.y + box.height / 2;
  };
  const add = await centre(component.getByTestId('add-computer'));
  const mac_ = await centre(component.getByTestId('companion-download'));
  const linux = await centre(component.getByTestId('companion-linux-link'));
  expect(Math.abs(add - mac_)).toBeLessThan(2);
  expect(Math.abs(add - linux)).toBeLessThan(2);
  await page.screenshot({ path: 'tmp/computers-header-1100.png' });
});
