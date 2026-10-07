import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test.describe(`message flags (${mobile ? 'touch' : 'desktop'})`, () => {
    if (mobile) test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

    test('identify their source, dismiss individually, and clear on reply', async ({ page, request }, testInfo) => {
      const setup = await (
        await request.post('/test/e2e/setup', {
          data: { run_id: `message-flags-${Date.now()}`, direct_tag_profile: true },
        })
      ).json();
      try {
        const { chat_id: chatId } = await (
          await request.post('/test/e2e/conversation_fixture', {
            data: { account_id: setup.account_id, count: 1 },
          })
        ).json();
        for (const content of ['@TagReader — first request.', '@TagReader — second request.', 'No request here.']) {
          const response = await request.post('/test/e2e/assistant_message', {
            data: { chat_id: chatId, content },
          });
          expect(response.ok()).toBe(true);
        }
        await page.goto('/login');
        await page.getByLabel(/email/i).fill(setup.primary_user.email);
        await page.getByLabel(/password/i).fill(setup.password);
        await page.getByRole('button', { name: /sign in|log in/i }).click();
        await expect(page).toHaveURL(/\/$/);
        await page.goto(`/accounts/${setup.account_id}/chats/${chatId}`);
        const tags = page.getByRole('button', { name: /This message appears to have flagged you/ });
        await expect(tags).toHaveCount(2);
        await expect(
          page
            .locator('section')
            .filter({ hasText: 'No request here.' })
            .getByRole('button', { name: /flagged you/ })
        ).toHaveCount(0);
        await page.reload();
        await expect(tags).toHaveCount(2);
        const second = page.locator('section').filter({ hasText: '@TagReader — second request.' });
        const tag = second.getByRole('button', { name: /This message appears/ });
        if (mobile) {
          await tag.tap();
          const explanation = page.getByText(/Tap again to dismiss this flag/);
          await expect(explanation).toBeVisible();
          await expect(tags).toHaveCount(2);
          await page.screenshot({ path: testInfo.outputPath('message-flag-touch.png') });
          await page.getByTestId('message-composer').locator('textarea').tap();
          await expect(explanation).not.toBeVisible();
          await tag.tap();
          await expect(explanation).toBeVisible();
          await expect(tags).toHaveCount(2);
          await tag.tap();
        } else {
          await page.screenshot({ path: testInfo.outputPath('message-flag-desktop.png') });
          await tag.focus();
          await page.keyboard.press('Enter');
        }
        await expect(tags).toHaveCount(1);
        await expect(second.getByRole('button', { name: /This message appears/ })).toHaveCount(0);
        await page.reload();
        await expect(tags).toHaveCount(1);
        const composer = page.getByTestId('message-composer');
        await expect(composer.getByRole('status')).toHaveText('Saved');
        await composer.locator('textarea').fill('Replying clears the remaining request.');
        await composer.getByRole('button', { name: 'Send message', exact: true }).click();
        await expect(tags).toHaveCount(0);
      } finally {
        await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
      }
    });
  });
}

test.describe('touch explanation', () => {
  test.use({ viewport: { width: 390, height: 844 }, hasTouch: true, isMobile: true });

  test('first tap explains, outside tap cancels, second tap dismisses', async ({ page, request }, testInfo) => {
    const setup = await (
      await request.post('/test/e2e/setup', {
        data: { run_id: `touch-attention-${Date.now()}`, direct_tag_profile: true },
      })
    ).json();
    try {
      const { chat_id: chatId } = await (
        await request.post('/test/e2e/conversation_fixture', {
          data: { account_id: setup.account_id, count: 1 },
        })
      ).json();
      await request.post('/test/e2e/assistant_message', {
        data: { chat_id: chatId, content: '@TagReader — please take a look.' },
      });
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /sign in|log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      await page.goto(`/accounts/${setup.account_id}/chats/new`);
      const eye = page
        .getByRole('navigation', { name: 'Recent conversations' })
        .getByRole('button', { name: /You have a mention or request/ });
      const explanation = page.getByText(/Tap again to dismiss the notification/);
      const originalUrl = page.url();
      await eye.tap();
      await expect(explanation).toBeVisible();
      await expect(eye).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath('touch-eye-explanation.png') });
      await page.getByRole('heading', { name: 'Start a new conversation' }).tap();
      await expect(explanation).not.toBeVisible();
      await expect(eye).toBeVisible();
      await eye.tap();
      await expect(explanation).toBeVisible();
      await eye.tap();
      await expect(eye).toHaveCount(0);
      await expect(explanation).not.toBeVisible();
      expect(page.url()).toBe(originalUrl);
      await page.reload();
      await expect(eye).toHaveCount(0);
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
});

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
      for (let i = 1; i < 4; i++) {
        await ask(`${firstMessage} Follow-up ${i}.`);
      }
      const accountMenu = page.getByRole('button', { name: 'User account menu' });
      await expect(accountMenu.getByLabel('1 thread requests your response')).toBeVisible();
      await accountMenu.click();
      await page.getByRole('menuitem', { name: /^Account(?! Settings)/ }).click();
      const targetAccount = page.getByRole('menuitem').filter({ hasText: `E2E ${setup.run_id} Team` });
      await expect(targetAccount.getByLabel('1 thread requests your response')).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath('reply-attention-accounts.png') });
      await targetAccount.click();
      const thread = page.locator(`aside a[href$="/chats/${chatId}"]`);
      await expect(page.locator('aside').getByRole('button', { name: /You have a mention or request/ })).toBeVisible();
      const eye = page.locator('aside').getByRole('button', { name: /You have a mention or request/ });
      await expect(eye).toHaveAttribute('title', /Click to dismiss.*Responding to the thread also dismisses/);
      const beforeDismiss = page.url();
      if (directTag) {
        await eye.focus();
        await page.keyboard.press('Enter');
      } else {
        await eye.click();
      }
      await expect(eye).toHaveCount(0);
      expect(page.url()).toBe(beforeDismiss);
      await ask(`${firstMessage} A new request after dismissal.`);
      await expect(eye).toBeVisible();
      await thread.click();
      await expect(page.getByText(firstMessage, { exact: true })).toBeVisible();
      await expect(page.locator('aside').getByRole('button', { name: /You have a mention or request/ })).toBeVisible();
      await page.reload();
      await expect(page.locator('aside').getByRole('button', { name: /You have a mention or request/ })).toBeVisible();
      await page.getByRole('button', { name: 'Conversation actions' }).click();
      await expect(page.getByRole('menuitem', { name: 'Dismiss request to respond' })).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath('reply-attention-dismiss.png') });
      await page.getByRole('menuitem', { name: 'Dismiss request to respond' }).click();
      await expect(page.locator('aside').getByRole('button', { name: /You have a mention or request/ })).toHaveCount(0);
      await expect(accountMenu.getByLabel('1 thread requests your response')).toHaveCount(0);
      await ask(
        directTag
          ? '@TagReader Example — another deliberate tag.'
          : 'Which location would you prefer for the synthetic meeting?'
      );
      await expect(page.locator('aside').getByRole('button', { name: /You have a mention or request/ })).toBeVisible();
      const composer = page.getByTestId('message-composer');
      await expect(composer.getByRole('status')).toHaveText('Saved');
      await composer.locator('textarea').fill("I'll look tonight");
      await composer.getByRole('button', { name: 'Send message', exact: true }).click();
      await expect(page.locator('aside').getByRole('button', { name: /You have a mention or request/ })).toHaveCount(0);
      await expect(accountMenu.getByLabel('1 thread requests your response')).toHaveCount(0);
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
}
