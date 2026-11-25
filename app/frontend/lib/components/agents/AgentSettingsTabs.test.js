import { render } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import { Gear, CloudArrowUp } from 'phosphor-svelte';
import AgentSettingsTabs from './AgentSettingsTabs.svelte';

const tabs = [
  { id: 'settings', label: 'Settings', icon: Gear },
  { id: 'hosting', label: 'Hosting', icon: CloudArrowUp, adminOnly: true },
];

test('an admin-only tab stays red whether or not it is selected', async () => {
  const view = render(AgentSettingsTabs, { tabs, activeTab: 'settings' });
  // The desktop rail; the phone picker's trigger is also a button.
  const railButton = (label) =>
    [...document.querySelectorAll('button:not([data-slot])')].find((button) => button.textContent.trim() === label);
  const hosting = () => railButton('Hosting');
  expect(hosting().className).toMatch(/text-red-600/);
  expect(railButton('Settings').className).toMatch(/bg-primary/);

  await view.rerender({ tabs, activeTab: 'hosting' });
  expect(hosting().className).toMatch(/text-red-700/);
  expect(hosting().className).not.toMatch(/bg-primary/);
  const trigger = document.querySelector('[data-slot="select-trigger"]');
  expect(trigger).toHaveAttribute('data-admin-only');
  expect(trigger.className).toMatch(/text-red-600/);
});
