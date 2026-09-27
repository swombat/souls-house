import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test(`progress groups immutable speech and preserves interruptions (${mobile ? 'mobile' : 'desktop'})`, async ({
    page,
    request,
  }, testInfo) => {
    const runId = `progress-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
    expect(setupResponse.ok()).toBe(true);
    const setup = await setupResponse.json();
    try {
      if (mobile) await page.setViewportSize({ width: 390, height: 844 });
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /sign in|log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1 },
      });
      const { chat_id: chatId } = await fixtureResponse.json();
      const started = await request.post('/test/e2e/runtime_activity', { data: { chat_id: chatId } });
      const { runtime_run_id: runtimeRunId } = await started.json();
      const post = async (content, options = {}) => {
        const response = await request.post('/test/e2e/assistant_message', {
          data: { chat_id: chatId, runtime_run_id: runtimeRunId, progress: true, content, ...options },
        });
        expect(response.ok()).toBe(true);
        return response.json();
      };
      await post('Checking the release.\n\n```text\nunclosed fence', { seconds_ago: 123 });
      await page.goto(`/accounts/${setup.account_id}/chats/${chatId}`);
      await expect(page.locator('[data-progress-section]')).toHaveCount(1);
      await post('**Live and checked.**');
      // Real message broadcasts update the same rendered group, not the first record.
      await expect(page.locator('[data-progress-section]')).toHaveCount(2);
      await expect(page.getByTestId('progress-status')).toHaveCount(1);
      await expect(page.locator('[data-progress-section] strong').getByText('Live and checked.')).toBeVisible();
      await expect(page.getByText(/2m \d{2}s elapsed/)).toBeVisible();
      await expect(page.getByTestId('progress-status')).toHaveText('In progress');
      await post('A separate thought.', { progress: false });
      await post('Continuation after the standalone post.');
      await expect(page.getByTestId('progress-status')).toHaveCount(2);
      await expect(page.getByText('Continued', { exact: true })).toBeVisible();
      await expect(page.getByText('A separate thought.', { exact: true })).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath('elapsed-dividers.png'), fullPage: true });
      await page.locator('main textarea').last().fill('Human interruption');
      await page.getByRole('button', { name: 'Send message', exact: true }).click();
      await expect(page.getByText('Human interruption', { exact: true })).toBeVisible();
      await post('Continuation after the human interruption.');
      await expect(page.getByTestId('progress-status')).toHaveCount(3);
      page.once('dialog', (dialog) => dialog.accept());
      await page.getByRole('button', { name: 'Delete message', exact: true }).last().click();
      await expect(page.getByText('Human interruption', { exact: true })).toBeHidden();
      await expect(page.getByTestId('progress-status')).toHaveCount(3);
      await page.reload();
      await expect(page.getByTestId('progress-status')).toHaveCount(3);

      const history = page.getByTestId('chat-messages');
      await history.evaluate((element) => {
        element.scrollTop = element.scrollHeight;
      });
      await post(Array.from({ length: 30 }, (_, i) => `Progress detail ${i}.`).join('\n\n'));
      await expect(page.locator('[data-progress-section]')).toHaveCount(5);
      await expect
        .poll(() => history.evaluate((element) => element.scrollHeight - element.clientHeight - element.scrollTop))
        .toBeLessThan(10);
      await history.evaluate((element) => {
        element.scrollTop = element.scrollHeight / 2;
      });
      const readingPosition = await history.evaluate((element) => element.scrollTop);
      await post('Another update while the reader is looking above.');
      await expect(page.locator('[data-progress-section]')).toHaveCount(6);
      expect(await history.evaluate((element) => element.scrollTop)).toBeCloseTo(readingPosition, 0);

      await request.post('/test/e2e/runtime_activity', {
        data: { chat_id: chatId, runtime_run_id: runtimeRunId, complete: true },
      });
      await expect(page.getByTestId('progress-status').last()).toHaveText('Wake ended');
      await page.reload();
      await expect(page.locator('[data-progress-section]')).toHaveCount(6);
      await expect(page.getByTestId('progress-status')).toHaveCount(3);
      await expect(page.getByTestId('progress-status').last()).toHaveText('Wake ended');
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
      await page.screenshot({ path: testInfo.outputPath('progress-messages.png'), fullPage: true });
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
    }
  });
}
