import { test, expect } from '@playwright/experimental-ct-svelte';
import PaidFallbackHarness from '../PaidFallbackHarness.svelte';

const policy = {
  available: true,
  imported_home: false,
  enabled: false,
  cap_usd: null,
  cap_period: 'month',
  committed_usd: '0.00',
  period_ends_at: '2026-11-23T00:00:00Z',
  payer_key_present: true,
  model_choices: [
    { model_id: 'first-model', label: 'First model' },
    { model_id: 'second-model', label: 'Second model' },
  ],
  api_keys_url: '/model-api-keys',
};

for (const width of [390, 1280]) {
  test(`owner can save paid fallback separately at ${width}px`, async ({ mount, page }, testInfo) => {
    await page.setViewportSize({ width, height: 900 });
    await page.route('**/paid-fallback-test', async (route) => {
      const request = route.request();
      if (request.method() === 'GET') return route.fulfill({ json: policy });

      const { fallback_policy } = request.postDataJSON();
      return route.fulfill({ json: { ...policy, ...fallback_policy, cap_usd: '12.34' } });
    });

    const component = await mount(PaidFallbackHarness);
    const card = component.getByTestId('paid-fallback-card');
    const toggle = card.getByRole('switch', { name: 'Answer on the paid fallback when the allowance runs out' });
    const model = card.getByRole('button', { name: 'Model', exact: true });
    const period = card.getByRole('button', { name: 'Per', exact: true });
    const cap = card.getByRole('spinbutton', { name: 'Cap (USD)' });

    await expect(toggle).not.toBeChecked();
    await expect(model).toHaveText('First model');
    await expect(period).toHaveText('month (from the 1st, UTC)');
    await cap.fill('0');
    await component.getByRole('button', { name: 'Update Resident' }).click();
    await expect(component.getByLabel('Resident updates')).toHaveText('1');

    await card.getByText('Answer on the paid fallback when the allowance runs out', { exact: true }).click();
    await expect(toggle).toBeChecked();
    await model.click();
    await page.getByRole('option', { name: 'Second model' }).click();
    await period.focus();
    await period.press('Enter');
    await period.press('ArrowUp');
    await period.press('Enter');
    await expect(period).toHaveText('week (from Monday, UTC)');
    await cap.fill('12.34');

    const [save] = await Promise.all([
      page.waitForRequest((request) => request.url().endsWith('/paid-fallback-test') && request.method() === 'PATCH'),
      card.getByRole('button', { name: 'Save paid fallback' }).click(),
    ]);
    expect(save.postDataJSON()).toEqual({
      fallback_policy: { enabled: true, model_id: 'second-model', cap_period: 'week', cap_usd: 12.34 },
    });
    await expect(card.getByText('Saved.', { exact: true })).toBeVisible();
    await expect(component.getByLabel('Resident updates')).toHaveText('1');
    await card.screenshot({ path: testInfo.outputPath('paid-fallback.png') });
  });
}
