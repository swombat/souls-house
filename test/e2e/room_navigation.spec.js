import { expect, test } from '@playwright/test';

test('room navigation stays live on a non-chat page, catches up and preserves drafts', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(90_000);
  const runId = `rooms-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const mutate = async (operation, extra = {}) => {
    const result = await request.post('/test/e2e/room_navigation_fixture', {
      data: { account_id: setup.account_id, operation, ...extra },
    });
    expect(result.ok()).toBe(true);
    return result.json();
  };
  let cable;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (socket) => {
    cable = socket;
    const server = socket.connectToServer();
    server.onMessage((raw) => {
      const data = JSON.parse(raw);
      if (data.type === 'confirm_subscription' && JSON.parse(data.identifier).model === 'RoomNavigation') {
        confirmed = true;
      }
      if (!drop || !data.message) socket.send(raw);
    });
  });
  try {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}`;
    await page.goto(`${base}/field`);
    await expect.poll(() => confirmed).toBe(true);
    const roomMenu = page.getByTestId('nav-chat-rooms');
    await expect(roomMenu).toHaveCount(0);
    const navDraft = page.getByPlaceholder('Search...', { exact: true });
    await navDraft.fill('Unsubmitted navigation search');

    const first = await mutate('create', { name: 'First live room' });
    await expect(roomMenu).toBeVisible();
    await roomMenu.click();
    await expect(page.getByRole('menuitem', { name: 'First live room', exact: true })).toBeVisible();
    await page.keyboard.press('Escape');
    expect(page.url()).toBe(`${new URL(page.url()).origin}${base}/field`);
    await expect(navDraft).toHaveValue('Unsubmitted navigation search');
    const second = await mutate('create', { name: 'Second live room' });
    await mutate('move', { room: second.id, direction: -1 });
    await roomMenu.click();
    await expect(page.getByRole('menuitem')).toHaveText(['Main', 'Second live room', 'First live room', 'All chats']);
    await page.keyboard.press('Escape');

    // The rename notification is lost: reconnect alone must refresh metadata.
    await page.waitForLoadState('networkidle');
    drop = true;
    await mutate('rename', { room: first.id, name: 'Renamed live room' });
    cable.close({ code: 1012, reason: 'Synthetic room reconnect' });
    await roomMenu.click();
    await expect(page.getByRole('menuitem', { name: 'Renamed live room', exact: true })).toBeVisible({
      timeout: 20_000,
    });
    drop = false;
    await expect(navDraft).toHaveValue('Unsubmitted navigation search');
    await page.screenshot({ path: testInfo.outputPath('rooms-live-reconnected.png'), fullPage: true });
    await page.getByRole('menuitem', { name: 'Renamed live room', exact: true }).click();
    await expect(page).toHaveURL(new RegExp(`/chats\\?room=${first.id}$`));
    const composer = page.getByTestId('message-composer').locator('textarea');
    await composer.fill('Unsent chat draft survives room deletion');
    const partial = page.waitForResponse(
      (res) =>
        res.url().includes('/chats') &&
        (res.request().headers()['x-inertia-partial-data'] || '').split(',').includes('current_room')
    );
    await mutate('delete', { room: first.id });
    expect((await (await partial).json()).props.current_room).toBe('main');
    await expect(composer).toHaveValue('Unsent chat draft survives room deletion');
    await mutate('delete', { room: second.id });
    await expect(roomMenu).toHaveCount(0);
    await expect(composer).toHaveValue('Unsent chat draft survives room deletion');
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
