import { test, expect } from '@playwright/experimental-ct-svelte';
import AgentTriggerBar from '../../app/frontend/lib/components/chat/AgentTriggerBar.svelte';

for (const width of [390, 1280]) {
  test(`usage refresh keeps buttons stationary at ${width}px`, async ({ mount, page }) => {
    await page.setViewportSize({ width, height: 844 });
    await page.clock.install();
    let requests = 0;
    let release;
    const pending = new Promise((resolve) => (release = resolve));
    await page.route('**/provider_subscription_usage', async (route) => {
      requests++;
      if (requests > 1) await pending;
      await route.fulfill({
        json: {
          windows: [{ id: 'session', remaining_percent: requests > 1 ? 79 : 80, resets_at: '2026-10-11T00:00:00Z' }],
        },
      });
    });
    const props = {
      accountId: 'refresh-account',
      chatId: 'chat',
      showUsage: true,
      agents: [
        {
          id: 'subscription',
          name: 'Resident',
          provider_subscription: {
            available: true,
            auth_mode: 'oauth_account',
            provider: 'openai',
            connection: { status: 'connected' },
          },
        },
        { id: 'api', name: 'API resident' },
      ],
    };
    const component = await mount(AgentTriggerBar, { props });
    const button = component.getByRole('button', { name: /^Resident/ });
    await expect(button).toHaveAccessibleName('Resident (80% left)');
    const bounds = await button.boundingBox();
    const other = component.getByRole('button', { name: 'API resident', exact: true });
    const otherBounds = await other.boundingBox();
    await button.evaluate((node) => (window.originalResidentButton = node));
    await page.clock.fastForward(61_000);
    await component.update({ props: { ...props, agents: props.agents.map((agent) => ({ ...agent })) } });
    await expect.poll(() => requests).toBe(2);
    await expect(button).toHaveAccessibleName('Resident (80% left)');
    expect(await button.boundingBox()).toEqual(bounds);
    expect(await other.boundingBox()).toEqual(otherBounds);
    release();
    await expect(button).toHaveAccessibleName('Resident (79% left)');
    expect(await button.boundingBox()).toEqual(bounds);
    expect(await other.boundingBox()).toEqual(otherBounds);
    expect(await button.evaluate((node) => node === window.originalResidentButton)).toBe(true);
  });
}

test('mobile subscription gauges fit the resident buttons and disappear on desktop', async ({
  mount,
  page,
}, testInfo) => {
  await page.setViewportSize({ width: 360, height: 800 });
  await page.route('**/provider_subscription_usage', (route) =>
    route.fulfill({
      json: {
        windows: [{ id: 'session', label: 'Session', remaining_percent: 20, resets_at: '2026-10-11T00:00:00Z' }],
      },
    })
  );
  const component = await mount(AgentTriggerBar, {
    props: {
      accountId: 'account',
      chatId: 'chat',
      showUsage: true,
      agents: [
        {
          id: 'subscription',
          name: 'Subscription resident',
          provider_subscription: {
            available: true,
            auth_mode: 'oauth_account',
            provider: 'openai',
            connection: { status: 'connected' },
          },
        },
        { id: 'api', name: 'API resident' },
      ],
    },
  });
  const button = component.getByRole('button', { name: 'Subscription resident (20% left)', exact: true });
  const gauge = button.locator('[data-subscription-gauge]');
  await expect(gauge).toBeVisible();
  await expect(component.locator('[data-subscription-gauge]')).toHaveCount(1);
  const buttonBounds = await button.boundingBox();
  const gaugeBounds = await gauge.boundingBox();
  const fillBounds = await gauge.locator('span').boundingBox();
  expect(gaugeBounds.x).toBeGreaterThan(buttonBounds.x + buttonBounds.width / 2);
  expect(gaugeBounds.x + gaugeBounds.width).toBeLessThan(buttonBounds.x + buttonBounds.width);
  expect(fillBounds.height / gaugeBounds.height).toBeCloseTo(0.2, 1);
  expect(fillBounds.y + fillBounds.height).toBeCloseTo(gaugeBounds.y + gaugeBounds.height, 0);
  await expect(button.locator('.md\\:inline')).toBeHidden();
  await page.screenshot({ path: testInfo.outputPath('mobile-subscription-gauge.png') });
  await page.evaluate(() => document.documentElement.classList.add('dark'));
  await page.screenshot({ path: testInfo.outputPath('mobile-subscription-gauge-dark.png') });
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(gauge).toBeHidden();
  await expect(button.locator('.md\\:inline')).toBeVisible();
});
