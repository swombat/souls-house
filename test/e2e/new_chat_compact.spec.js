import { expect, test } from '@playwright/test';

test('on a phone, new chat keeps room, residents and composer compact', async ({ page, request }, testInfo) => {
  const response = await request.post('/test/e2e/setup', { data: { run_id: `new-chat-compact-${Date.now()}` } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    const room = await request.post('/test/e2e/room_navigation_fixture', {
      data: { account_id: setup.account_id, operation: 'create', name: 'Work' },
    });
    expect(room.ok()).toBe(true);
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/accounts/${setup.account_param}/chats/new`);

    const header = page.locator('main header');
    await expect(header.getByTitle('Edit chat title')).toBeVisible();
    await expect(header.getByTestId('new-chat-room')).toBeVisible();
    await expect(page.getByTestId('new-chat-room')).toHaveCount(1);
    await expect(page.getByTestId('participant-summary')).toBeVisible();
    await expect(page.getByText(/Draft saved only in this browser/)).toBeHidden();
    await page.screenshot({ path: testInfo.outputPath('new-chat-phone.png') });

    await page.setViewportSize({ width: 1280, height: 900 });
    await expect(header.getByTestId('new-chat-room')).toBeHidden();
    await expect(page.getByText(/Draft saved only in this browser/)).toBeVisible();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});

for (const width of [390, 1280]) {
  test(`new chats follow the active room at ${width}px`, async ({ page, request }, testInfo) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `new-chat-room-${width}-${Date.now()}` },
    });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      const roomResponse = await request.post('/test/e2e/room_navigation_fixture', {
        data: { account_id: setup.account_id, operation: 'create', name: 'Work' },
      });
      expect(roomResponse.ok()).toBe(true);
      const room = await roomResponse.json();
      const chatsPath = `/accounts/${setup.account_param}/chats`;
      await page.setViewportSize({ width, height: 844 });
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /log in/i }).click();
      await expect(page).not.toHaveURL(/\/login/);

      async function createChat(title) {
        await page.getByTitle('Edit chat title').click();
        await page.locator('header input[type="text"]').fill(title);
        await page.locator('header input[type="text"]').press('Enter');
        const created = page.waitForResponse(
          (res) => res.request().method() === 'POST' && new URL(res.url()).pathname === chatsPath
        );
        await page.getByTestId('message-composer').locator('textarea').fill('Synthetic room test');
        await page.getByRole('button', { name: 'Start conversation' }).click();
        const result = await created;
        expect(result.status()).toBeLessThan(400);
        await expect(page).toHaveURL(/\/chats\/[^/]+$/);
      }

      await page.goto(`${chatsPath}?room=main`);
      await createChat('Main conversation');
      await page.goto(`${chatsPath}?room=${room.id}`);
      await createChat('Work conversation');
      // Explicit new-chat URLs must inherit the selected room too.
      await page.goto(`${chatsPath}/new`);
      const switcher = page.getByTestId('new-chat-room');
      if (width < 768) {
        await expect(switcher).toHaveText('Work');
        const recent = page.getByRole('navigation', { name: 'Recent conversations' });
        await expect(recent.getByRole('link')).toHaveText(['Work conversation']);
        await switcher.click();
        await page.getByRole('option', { name: 'Main', exact: true }).click();
        await expect(page).toHaveURL(new RegExp(`/chats\\?room=main$`));
        await expect(switcher).toHaveText('Main');
        await expect(recent.getByRole('link')).toHaveText(['Main conversation']);
        await switcher.click();
        await page.getByRole('option', { name: 'Work', exact: true }).click();
        await expect(page).toHaveURL(new RegExp(`/chats\\?room=${room.id}$`));
        await expect(recent.getByRole('link')).toHaveText(['Work conversation']);
        await page.screenshot({ path: testInfo.outputPath('mobile-room-switched.png') });
        await createChat('Work after switching');
        await page.goto(`${chatsPath}?room=${room.id}`);
        await expect(recent.getByRole('link')).toHaveText(['Work after switching', 'Work conversation']);
        await page.goto(`${chatsPath}?room=main`);
        await expect(recent.getByRole('link')).toHaveText(['Main conversation']);
      } else {
        await expect(switcher).toBeHidden();
        await createChat('Desktop inherited room');
        await page.goto(`${chatsPath}?room=${room.id}`);
        const sidebar = page.locator('[data-chat-sidebar-scroller]');
        await expect(sidebar.getByText('Desktop inherited room', { exact: true })).toBeVisible();
        await expect(sidebar.getByText('Main conversation', { exact: true })).toHaveCount(0);
      }
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
}
