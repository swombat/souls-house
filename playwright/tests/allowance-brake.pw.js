import { test, expect } from '@playwright/experimental-ct-svelte';
import AllowanceBrakeHarness from '../AllowanceBrakeHarness.svelte';

for (const width of [390, 1280]) {
  test(`owner explicitly enables the brake at ${width}px`, async ({ mount, page }, testInfo) => {
    await page.setViewportSize({ width, height: 950 });
    const component = await mount(AllowanceBrakeHarness);
    await expect(component.getByLabel('Brake below remaining allowance (%)')).toHaveCount(0);
    await component.getByRole('switch', { name: 'Enable allowance brake' }).click();
    await expect(component.getByLabel('Brake below remaining allowance (%)')).toHaveValue('40');
    await component.getByLabel('Brake below remaining allowance (%)').fill('35');
    await component.getByRole('switch', { name: 'Heartbeats are essential' }).click();
    await expect(component.getByRole('switch', { name: 'Heartbeats are essential' })).toBeChecked();
    await page.screenshot({ path: testInfo.outputPath('allowance-brake.png'), fullPage: true });
  });
}

test('non-manager has no essential or threshold controls', async ({ mount }) => {
  const component = await mount(AllowanceBrakeHarness, { props: { canManage: false } });
  await expect(component.getByRole('switch')).toHaveCount(0);
  await expect(component).toContainText('Only the owner or an account admin');
});
