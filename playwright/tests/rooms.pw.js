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

const mira = { id: 'mira', name: 'Mira', colour: 'violet' };
const lume = { id: 'lume', name: 'Lume', colour: 'orange' };
const working = { rooms: { devRm: [mira, lume] }, all: [mira, lume] };

test('the switcher spins beside a room where residents are working, in the newest colour', async ({ mount, page }) => {
  const component = await mount(RoomsHarness, { props: { account, rooms, current_room: 'lifeRm', waiting: { devRm: 1 }, working } });
  await component.getByTestId('room-switcher').click();
  const dev = page.getByRole('option', { name: /Dev/ });
  const spinner = dev.getByTestId('room-working');
  await expect(spinner).toBeVisible();
  await expect(spinner).toHaveAttribute('data-colour', 'violet');
  await expect(spinner).toHaveAttribute('title', 'Mira and Lume working');
  await expect(dev).toContainText('1');
  await expect(page.getByRole('option', { name: /Life/ }).getByTestId('room-working')).toHaveCount(0);
  await expect(page.getByRole('option', { name: /All chats/ }).getByTestId('room-working')).toBeVisible();
  const colour = await spinner.evaluate((el) => getComputedStyle(el).borderTopColor);
  expect(colour).not.toBe('rgba(0, 0, 0, 0)');
  await page.screenshot({ path: 'tmp/rooms-switcher-working.png' });
});

test('the navbar Chats menu shows the same spinner', async ({ mount, page }) => {
  const component = await mount(RoomsHarness, { props: { account, rooms, working } });
  await component.getByTestId('nav-chat-rooms').click();
  const dev = page.getByRole('menuitem', { name: /Dev/ });
  await expect(dev.getByTestId('room-working')).toHaveAttribute('data-colour', 'violet');
  await expect(page.getByRole('menuitem', { name: /Main/ }).getByTestId('room-working')).toHaveCount(0);
  await page.screenshot({ path: 'tmp/rooms-nav-working.png' });
});
