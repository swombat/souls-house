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
    await expect(page.getByText(/Draft saved only in this browser/)).toBeVisible();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
