import { expect, test } from '@playwright/experimental-ct-svelte';
import AgentRuntimeActivityCard from '../../app/frontend/lib/components/chat/AgentRuntimeActivityCard.svelte';

for (const dark of [false, true]) {
  test(`resident background survives completion in ${dark ? 'dark' : 'light'} mode`, async ({ mount, page }) => {
    await page.evaluate((enabled) => document.documentElement.classList.toggle('dark', enabled), dark);
    const interaction = {
      id: 'colour-test',
      run_id: 'colour-run',
      agent_name: 'Resident',
      agent_colour: 'violet',
      active: true,
      status_label: 'is working',
      created_at: '2026-09-30T13:00:00Z',
      snapshot: { commentary: 'Checking the colours.' },
    };
    const component = await mount(AgentRuntimeActivityCard, { props: { interaction } });
    const details = component.locator('details');
    const background = await details.evaluate((element) => {
      const reference = document.createElement('div');
      reference.className = 'bg-violet-100 dark:bg-violet-900';
      document.body.append(reference);
      const expected = getComputedStyle(reference).backgroundColor;
      reference.remove();
      return { actual: getComputedStyle(element).backgroundColor, expected };
    });
    expect(background.actual).not.toBe('rgba(0, 0, 0, 0)');
    expect(background.actual).toBe(background.expected);
    await expect(details).toHaveAttribute('open', '');
    await component.update({
      props: { interaction: { ...interaction, active: false, status_label: 'finished' } },
    });
    await expect(details).not.toHaveAttribute('open');
    await expect(details).toHaveCSS('background-color', background.actual);
    await details.locator('summary').click();
    await expect(details).toHaveAttribute('open', '');
    await expect(details).toHaveCSS('background-color', background.actual);
  });
}
