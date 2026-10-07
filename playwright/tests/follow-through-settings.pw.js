import { test, expect } from '@playwright/experimental-ct-svelte';
import FollowThroughSettingsCard from '../../app/frontend/lib/components/admin/FollowThroughSettingsCard.svelte';

const residents = [
  { id: 'BJZbJx', name: 'Lume', account: 'Daniel, Lume and Mira', icon: 'Sun', colour: 'orange', follow_through: true },
  {
    id: 'AYawJx',
    name: 'Mira',
    account: 'Daniel, Lume and Mira',
    icon: 'Moon',
    colour: 'violet',
    follow_through: false,
  },
  { id: 'QQqqQQ', name: 'Wing', account: 'Paulina', icon: 'Bird', colour: 'sky', paused: true, follow_through: false },
];

test('follow-through card switches scope and lists residents to pick', async ({ mount, page }) => {
  const component = await mount(FollowThroughSettingsCard, {
    props: { form: { follow_through_scope: 'selected' }, residents, picked: ['BJZbJx'] },
  });
  await expect(component.getByText('1 of 3 chosen')).toBeVisible();
  await expect(component.getByRole('switch', { name: 'Follow-through for Lume' })).toBeChecked();
  await component.getByRole('switch', { name: 'Follow-through for Mira' }).click();
  await expect(component.getByText('2 of 3 chosen')).toBeVisible();
  await page.screenshot({ path: 'tmp/follow-through-settings.png', fullPage: true });
});
