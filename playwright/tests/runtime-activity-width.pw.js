import { expect, test } from '@playwright/experimental-ct-svelte';
import AgentRuntimeActivityCard from '../../app/frontend/lib/components/chat/AgentRuntimeActivityCard.svelte';

for (const viewportWidth of [1280, 390]) {
  test(`activity width follows visible content at ${viewportWidth}px`, async ({ mount, page }) => {
    await page.setViewportSize({ width: viewportWidth, height: 900 });
    const interaction = {
      id: 'width-test',
      run_id: 'width-run',
      agent_name: 'Mira',
      active: false,
      status_label: 'finished',
      created_at: '2026-10-01T11:00:00Z',
      snapshot: { commentary: 'Checking.' },
      events: [
        { id: 'command', type: 'operation.completed', data: { label: `curl https://example.test/${'x'.repeat(500)}` } },
      ],
    };
    const component = await mount(AgentRuntimeActivityCard, { props: { interaction } });
    const details = component.locator('details');
    const width = () => details.evaluate((element) => element.getBoundingClientRect().width);
    const collapsed = await width();
    expect(collapsed).toBeLessThan(viewportWidth * 0.6);
    await details.locator('summary').click();
    const narration = await width();
    expect(narration).toBeGreaterThan(collapsed);
    await component.getByRole('button', { name: 'Show commands' }).click();
    const commands = await width();
    if (viewportWidth > 768) expect(commands).toBeGreaterThan(narration);
    expect(commands).toBeLessThanOrEqual(viewportWidth * (viewportWidth > 768 ? 0.75 : 0.9));
    expect(await details.evaluate((element) => element.scrollWidth <= element.clientWidth)).toBe(true);
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await component.getByRole('button', { name: 'Hide commands' }).click();
    expect(await width()).toBeCloseTo(narration, 0);
    await details.locator('summary').click();
    expect(await width()).toBeCloseTo(collapsed, 0);
  });
}
