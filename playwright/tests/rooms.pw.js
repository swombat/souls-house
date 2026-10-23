import { test, expect } from '@playwright/experimental-ct-svelte';
import RoomsHarness from '../RoomsHarness.svelte';

const account = { id: 'acc', name: 'Daniel, Lume and Mira' };
const rooms = [
  { id: 'lifeRm', name: 'Life', conversation_count: 4, description: 'home, family and anything personal' },
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
  await expect(component.getByTestId('room-description')).toHaveText('home, family and anything personal');
  await page.screenshot({ path: 'tmp/rooms-settings.png', fullPage: true });
});

test('the switcher shows waiting counts inside the menu only', async ({ mount, page }) => {
  const component = await mount(RoomsHarness, {
    props: { account, rooms, current_room: 'devRm', waiting: { lifeRm: 2 } },
  });
  const trigger = component.getByTestId('room-switcher');
  await expect(trigger).toHaveText('Dev');
  await expect(trigger).not.toContainText('2');
  // Keyboard (and touch) keep the select.
  await trigger.focus();
  await page.keyboard.press('Enter');
  await expect(page.getByRole('option', { name: /Life/ })).toContainText('2');
  await expect(page.getByRole('option', { name: 'All chats' })).toBeVisible();
  await page.screenshot({ path: 'tmp/rooms-switcher.png' });
});

test('with a mouse, resting on the room name lists the rooms; clicking it does not stack the select on top', async ({
  mount,
  page,
}) => {
  const component = await mount(RoomsHarness, {
    props: { account, rooms, current_room: 'devRm', waiting: { lifeRm: 2 } },
  });
  const trigger = component.getByTestId('room-switcher');
  await trigger.hover();
  const panel = component.getByTestId('room-hover-switcher-panel');
  await expect(panel).toBeVisible();
  await expect(panel.getByRole('link', { name: /Life/ })).toContainText('2');
  await expect(panel.getByRole('link', { name: /Dev/ })).toHaveAttribute('aria-current', 'page');
  await expect(panel.getByRole('link', { name: 'All chats' })).toHaveAttribute('href', '/accounts/acc/chats?room=all');
  await page.screenshot({ path: 'tmp/rooms-hover-switcher.png' });
  await trigger.click();
  await expect(page.getByRole('listbox')).toHaveCount(0);
  await expect(panel).toBeVisible();
  // Moving down into the list keeps it open; leaving closes it.
  await panel.getByRole('link', { name: /Life/ }).hover();
  await expect(panel).toBeVisible();
  await page.mouse.move(600, 600);
  await expect(panel).toHaveCount(0);
});

const mira = { id: 'mira', name: 'Mira', colour: 'violet' };
const lume = { id: 'lume', name: 'Lume', colour: 'orange' };
const working = { rooms: { devRm: [mira, lume] }, all: [mira, lume] };

test('the switcher spins beside a room where residents are working, a ring for each', async ({ mount, page }) => {
  const component = await mount(RoomsHarness, {
    props: { account, rooms, current_room: 'lifeRm', waiting: { devRm: 1 }, working },
  });
  await component.getByTestId('room-switcher').focus();
  await page.keyboard.press('Enter');
  const dev = page.getByRole('option', { name: /Dev/ });
  const spinner = dev.getByTestId('room-working');
  await expect(spinner).toBeVisible();
  await expect(spinner).toHaveAttribute('data-colour', 'violet');
  await expect(spinner).toHaveAttribute('title', 'Mira and Lume working');
  await expect(dev).toContainText('1');
  await expect(page.getByRole('option', { name: /Life/ }).getByTestId('room-working')).toHaveCount(0);
  await expect(page.getByRole('option', { name: /All chats/ }).getByTestId('room-working')).toBeVisible();
  const rings = spinner.getByTestId('room-working-ring');
  await expect(rings).toHaveCount(2);
  const colours = await rings.evaluateAll((els) => els.map((el) => getComputedStyle(el).borderTopColor));
  expect(colours[0]).not.toBe('rgba(0, 0, 0, 0)');
  expect(colours[1]).not.toBe('rgba(0, 0, 0, 0)');
  expect(colours[0]).not.toBe(colours[1]);
  await page.screenshot({ path: 'tmp/rooms-switcher-working.png' });
});

test('the navbar Chats menu shows the same spinner', async ({ mount, page }) => {
  const component = await mount(RoomsHarness, { props: { account, rooms, working } });
  await component.getByTestId('nav-chat-rooms').click();
  const dev = page.getByRole('menuitem', { name: /Dev/ });
  await expect(dev.getByTestId('room-working')).toHaveAttribute('data-colour', 'violet');
  await expect(page.getByRole('menuitem', { name: /Main/ }).getByTestId('room-working')).toHaveCount(0);
  await expect(page.getByTestId('manage-rooms')).toHaveText('Manage rooms…');
  await page.screenshot({ path: 'tmp/rooms-nav-working.png' });
});

test.describe('touch', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test('on a phone, tapping the room name opens the select (no hover list) and tapping a room goes there', async ({
    mount,
    page,
  }) => {
    const visited = [];
    await page.route('**/accounts/acc/chats?room=*', (route) => {
      visited.push(new URL(route.request().url()).search);
      route.fulfill({ status: 204, body: '' });
    });
    const component = await mount(RoomsHarness, {
      props: { account, rooms, current_room: 'devRm', waiting: { lifeRm: 2 } },
    });
    await component.getByTestId('room-switcher').tap();
    const life = page.getByRole('option', { name: /Life/ });
    await expect(life).toBeVisible();
    await expect(life).toContainText('2');
    await expect(component.getByTestId('room-hover-switcher-panel')).toHaveCount(0);
    await life.tap();
    await expect.poll(() => visited).toEqual(['?room=lifeRm']);
  });

  test('on a phone, each room keeps its name and description full width, with its controls on a line below', async ({
    mount,
    page,
  }) => {
    const longRooms = [
      {
        id: 'planRm',
        name: 'Planning',
        conversation_count: 32,
        description: 'Planning work, usually in Fable/Astra mode',
      },
      {
        id: 'convRm',
        name: 'Conversations',
        conversation_count: 14,
        description: 'Having conversations about complex topics, usually in Fable/Astra mode',
      },
    ];
    const component = await mount(RoomsHarness, {
      props: {
        account,
        rooms: longRooms,
        main_room: { id: null, name: 'General', description: 'Builds and anything without a better home' },
      },
    });
    const row = component.getByTestId('room-row').nth(1);
    const name = row.getByText('Conversations', { exact: true });
    const description = row.getByTestId('room-description');
    const edit = row.getByRole('button', { name: 'Edit Conversations' });
    const nameBox = await name.boundingBox();
    const descriptionBox = await description.boundingBox();
    const editBox = await edit.boundingBox();
    expect(await name.evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
    expect(descriptionBox.width).toBeGreaterThan(250);
    expect(descriptionBox.height).toBeLessThan(60);
    expect(editBox.y).toBeGreaterThanOrEqual(descriptionBox.y + descriptionBox.height - 1);
    expect(nameBox.y).toBeLessThan(descriptionBox.y);

    const main = component.getByTestId('main-room-row');
    await expect(main).toContainText('General');
    await expect(main).toContainText('Builds and anything without a better home');
    await expect(main.getByRole('button', { name: 'Edit General' })).toBeVisible();
    await expect(main.getByRole('button', { name: 'Remove General' })).toHaveCount(0);
    await page.screenshot({ path: 'tmp/rooms-settings-phone.png', fullPage: true });
  });
});
