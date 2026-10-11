import { test, expect } from '@playwright/experimental-ct-svelte';
import RoomsHarness from '../RoomsHarness.svelte';

const account = { id: 'acc', name: 'Daniel, Lume and Mira' };
const rooms = [
  { id: 'lifeRm', name: 'Life', conversation_count: 4 },
  { id: 'devRm', name: 'Dev', conversation_count: 30 },
];

test('rooms settings list Main first and offer the resident default', async ({ mount, page }) => {
  const component = await mount(RoomsHarness, { props: { account, rooms, resident_room_id: 'devRm' } });
  const rows = component.getByTestId('room-row');
  await expect(rows).toHaveCount(2);
  await expect(component.getByText('12 conversations · default')).toBeVisible();
  await expect(component.getByRole('button', { name: 'Move Life up' })).toBeDisabled();
  await expect(component.getByRole('button', { name: 'Move Dev down' })).toBeDisabled();
  await expect(component.getByLabel('Default room for resident-started conversations')).toHaveText('Dev');
  await page.screenshot({ path: 'tmp/rooms-settings.png', fullPage: true });
});

test('the switcher shows waiting counts inside the menu only', async ({ mount, page }) => {
  const component = await mount(RoomsHarness, {
    props: { account, rooms, current_room: 'devRm', waiting: { lifeRm: 2 } },
  });
  const trigger = component.getByTestId('room-switcher');
  await expect(trigger).toHaveText('Dev');
  await expect(trigger).not.toContainText('2');
  await trigger.click();
  await expect(page.getByRole('option', { name: /Life/ })).toContainText('2');
  await expect(page.getByRole('option', { name: 'All chats' })).toBeVisible();
  await page.screenshot({ path: 'tmp/rooms-switcher.png' });
});
