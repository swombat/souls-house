import { expect, test } from '@playwright/test';

test('Enter shows the automatic wake without a manual trigger or websocket notifications', async ({
  page,
  request,
}, testInfo) => {
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `solo-activity-${Date.now()}` },
  });
  const setup = await response.json();
  try {
    const fixture = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 0, resident_count: 1 },
    });
    const { chat_id: chatId } = await fixture.json();
    let dropNotifications = false;
    await page.routeWebSocket('**/cable', (socket) => {
      const server = socket.connectToServer();
      server.onMessage((message) => {
        if (!dropNotifications) socket.send(message);
      });
    });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/chats/${chatId}`);
    await page.waitForLoadState('networkidle');
    dropNotifications = true;
    const composer = page.getByTestId('message-composer').locator('textarea');
    await composer.fill('Please start working from Enter alone');
    await composer.press('Enter');
    await expect(page.getByText('Please start working from Enter alone', { exact: true })).toBeVisible();
    const card = page.getByTestId('runtime-activity-card');
    await expect(card).toHaveCount(1);
    await expect(card).toBeVisible();
    await expect(card).toContainText('E2E Researcher');
    await expect(page.getByRole('button', { name: 'E2E Researcher', exact: true })).toBeDisabled();
    await page.screenshot({ path: testInfo.outputPath('automatic-wake-visible.png') });
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
