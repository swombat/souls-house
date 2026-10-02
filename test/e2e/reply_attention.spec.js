import { expect, test } from '@playwright/test';

for (const directTag of [false, true]) {
  test(`cross-account attention badges, persistent eye, dismissal and reply clearing (${directTag ? 'direct tag' : 'inferred'})`, async ({
    page,
    request,
  }, testInfo) => {
    const setupResponse = await request.post('/test/e2e/setup', {
      data: { run_id: `attention-${Date.now()}-${Math.random().toString(36).slice(2)}`, direct_tag_profile: directTag },
    });
    const setup = await setupResponse.json();
    try {
      const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1 },
      });
      const { chat_id: chatId } = await fixtureResponse.json();
      const ask = async (content) => {
        const response = await request.post('/test/e2e/assistant_message', {
          data: { chat_id: chatId, content, ...(directTag ? {} : { reply_attention_email: setup.primary_user.email }) },
        });
        expect(response.ok()).toBe(true);
      };
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /sign in|log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      // Stay in the other account when the question arrives.
      await page.goto(`/accounts/${setup.empty_account_id}/chats`);
      const firstMessage = directTag
        ? '@TagReader — tagging you, as asked.'
        : 'Could you choose a date for our synthetic meeting?';
      await ask(firstMessage);
      const accountMenu = page.getByRole('button', { name: 'User account menu' });
      await expect(accountMenu.getByLabel('1 message requests your response')).toBeVisible();
      await accountMenu.click();
      await page
        .getByRole('menuitem')
        .filter({ hasText: /^Account/ })
        .hover();
      const targetAccount = page.getByRole('menuitem').filter({ hasText: `E2E ${setup.run_id} Team` });
      await expect(targetAccount.getByLabel('1 message requests your response')).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath('reply-attention-accounts.png') });
      await targetAccount.click();
      const thread = page.locator(`aside a[href$="/chats/${chatId}"]`);
      await expect(thread.getByLabel('Your response is requested')).toBeVisible();
      await thread.click();
      await expect(page.getByText(firstMessage, { exact: true })).toBeVisible();
      await expect(thread.getByLabel('Your response is requested')).toBeVisible();
      await page.reload();
      await expect(thread.getByLabel('Your response is requested')).toBeVisible();
      await page.getByRole('button', { name: 'Conversation actions' }).click();
      await expect(page.getByRole('menuitem', { name: 'Dismiss request to respond' })).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath('reply-attention-dismiss.png') });
      await page.getByRole('menuitem', { name: 'Dismiss request to respond' }).click();
      await expect(thread.getByLabel('Your response is requested')).toHaveCount(0);
      await expect(accountMenu.getByLabel('1 message requests your response')).toHaveCount(0);
      await ask(
        directTag
          ? '@TagReader Example — another deliberate tag.'
          : 'Which location would you prefer for the synthetic meeting?'
      );
      await expect(thread.getByLabel('Your response is requested')).toBeVisible();
      const composer = page.getByTestId('message-composer');
      await expect(composer.getByRole('status')).toHaveText('Saved');
      await composer.locator('textarea').fill("I'll look tonight");
      await composer.getByRole('button', { name: 'Send message', exact: true }).click();
      await expect(thread.getByLabel('Your response is requested')).toHaveCount(0);
      await expect(accountMenu.getByLabel('1 message requests your response')).toHaveCount(0);
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
}
