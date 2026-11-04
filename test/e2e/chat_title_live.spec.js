import { expect, test } from '@playwright/test';

// Daniel, YAqgdY 2026-11-04: a conversation born empty stayed "New
// Conversation" after its first message. The title now arrives seconds later
// (GenerateTitleJob) and must reach a header that is already open, without a
// reload, as it used to.
test('a title given after the page opened reaches the header live', async ({ page, request }) => {
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `title-live-${Date.now()}-${Math.random().toString(36).slice(2)}` },
  });
  const setup = await response.json();
  try {
    const fixture = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 1, title: '' },
    });
    const { chat_id: chatId } = await fixture.json();

    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/accounts/${setup.account_param}/chats/${chatId}`);

    const heading = page.getByTitle('Edit chat title', { exact: true });
    await expect(heading).toHaveText('New Chat');

    const titled = await request.post('/test/e2e/title_chat', {
      data: { chat_id: chatId, title: 'Planning the autumn walk' },
    });
    expect(titled.ok()).toBeTruthy();

    await expect(heading).toHaveText('Planning the autumn walk');
    await expect(page).toHaveTitle(/Planning the autumn walk/);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
