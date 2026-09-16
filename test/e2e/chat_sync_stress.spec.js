import { expect, test } from '@playwright/test';

async function login(page, user, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(user.email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

async function setupRun(request) {
  const runId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  return response.json();
}

async function cleanupRun(request, runId) {
  await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
}

async function seedConversation(request, setup, options = {}) {
  const response = await request.post('/test/e2e/conversation_fixture', {
    data: {
      account_id: setup.account_id,
      count: options.count ?? 65,
      prefix: options.prefix ?? 'History message',
    },
  });
  expect(response.ok()).toBe(true);
  return response.json();
}

async function appendMessages(request, chatId, options = {}) {
  const response = await request.post('/test/e2e/append_messages', {
    data: {
      chat_id: chatId,
      count: options.count ?? 1,
      prefix: options.prefix ?? 'Live message',
      delay_ms: options.delayMs ?? 0,
    },
  });
  expect(response.ok()).toBe(true);
  return response.json();
}

async function openChat(page, setup, chatId) {
  await login(page, setup.primary_user, setup.password);
  await page.goto(`/accounts/${setup.account_id}/chats/${chatId}`);
}

test.describe('long conversation synchronization', () => {
  let setup;

  test.beforeEach(async ({ request }) => {
    setup = await setupRun(request);
  });

  test.afterEach(async ({ request }) => {
    await cleanupRun(request, setup.run_id);
  });

  test('reconnecting catches up messages whose notifications were missed', async ({ page, request }) => {
    let socketToReconnect;
    let subscribed = false;
    let dropNotifications = false;
    await page.routeWebSocket('**/cable', (socket) => {
      socketToReconnect = socket;
      const server = socket.connectToServer();
      server.onMessage((message) => {
        const data = JSON.parse(message);
        if (data.type === 'confirm_subscription' && JSON.parse(data.identifier).model === 'Chat') {
          subscribed = true;
        }
        if (!dropNotifications || !data.message) socket.send(message);
      });
    });
    const conversation = await seedConversation(request, setup, { count: 1 });
    await openChat(page, setup, conversation.chat_id);
    await expect.poll(() => subscribed).toBe(true);
    await page.waitForLoadState('networkidle');
    dropNotifications = true;
    await appendMessages(request, conversation.chat_id, { prefix: 'Missed while disconnected' });
    // No later broadcast will rescue this message: only reconnect reconciliation can.
    socketToReconnect.close({ code: 1012, reason: 'Test reconnect' });
    await expect(page.getByText('Missed while disconnected 000', { exact: true })).toBeVisible({
      timeout: 20000,
    });
  });

  test('keeps paginated history while new messages synchronize', async ({ page, request }) => {
    const conversation = await seedConversation(request, setup);
    await openChat(page, setup, conversation.chat_id);

    // The initial page contains only the newest 30 of 65 messages.
    await expect(page.getByText('History message 064', { exact: true })).toBeVisible();
    await expect(page.getByText('History message 000', { exact: true })).toHaveCount(0);

    // Load both older pages and prove the cursor boundary has no gaps.
    await page.getByRole('button', { name: 'Load earlier messages' }).click();
    await expect(page.getByText('History message 005', { exact: true })).toBeVisible();
    await expect(page.getByText('History message 034', { exact: true })).toBeVisible();
    await page.getByRole('button', { name: 'Load earlier messages' }).click();
    await expect(page.getByText('History message 000', { exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Load earlier messages' })).toHaveCount(0);

    await appendMessages(request, conversation.chat_id, { count: 3, prefix: 'After pagination' });

    await expect(page.getByText('After pagination 002', { exact: true })).toBeVisible();
    await expect(page.getByText('History message 000', { exact: true })).toBeVisible();
    await expect(page.getByText('History message 034', { exact: true })).toHaveCount(1);
    await expect(page.getByText('History message 035', { exact: true })).toHaveCount(1);
  });

  test('two windows converge after a burst overlaps reloads and resubscriptions', async ({
    browser,
    page,
    request,
  }) => {
    const conversation = await seedConversation(request, setup, { count: 31 });
    await openChat(page, setup, conversation.chat_id);

    const secondContext = await browser.newContext();
    const secondPage = await secondContext.newPage();
    await login(secondPage, setup.secondary_user, setup.password);
    await secondPage.goto(page.url());

    const burst = await appendMessages(request, conversation.chat_id, {
      count: 12,
      prefix: 'Burst message',
      delayMs: 75,
    });

    for (const { content } of burst.messages) {
      await expect(page.getByText(content, { exact: true })).toHaveCount(1);
      await expect(secondPage.getByText(content, { exact: true })).toHaveCount(1);
    }

    const firstWindowText = await page.locator('main').last().innerText();
    const secondWindowText = await secondPage.locator('main').last().innerText();
    for (let index = 1; index < burst.messages.length; index += 1) {
      const previous = burst.messages[index - 1].content;
      const current = burst.messages[index].content;
      expect(firstWindowText.indexOf(previous)).toBeLessThan(firstWindowText.indexOf(current));
      expect(secondWindowText.indexOf(previous)).toBeLessThan(secondWindowText.indexOf(current));
    }

    await secondContext.close();
  });

  test('simultaneous writers are reflected once in both windows', async ({ browser, page, request }) => {
    const conversation = await seedConversation(request, setup, { count: 31 });
    await openChat(page, setup, conversation.chat_id);

    const secondContext = await browser.newContext();
    const secondPage = await secondContext.newPage();
    await login(secondPage, setup.secondary_user, setup.password);
    await secondPage.goto(page.url());

    await Promise.all([
      page.locator('main textarea').last().fill('Message from primary window'),
      secondPage.locator('main textarea').last().fill('Message from secondary window'),
    ]);
    await Promise.all([page.locator('main button').last().click(), secondPage.locator('main button').last().click()]);

    for (const window of [page, secondPage]) {
      await expect(window.getByText('Message from primary window', { exact: true })).toHaveCount(1);
      await expect(window.getByText('Message from secondary window', { exact: true })).toHaveCount(1);
    }

    await secondContext.close();
  });
});
