import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test.describe(`completion handoff (${mobile ? 'mobile' : 'desktop'})`, () => {
    if (mobile) test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    test('save, review, accept and safely close a handoff', async ({ page, request }, testInfo) => {
      const response = await request.post('/test/e2e/setup', {
        data: { run_id: `work-completion-${mobile}-${Date.now()}` },
      });
      expect(response.ok()).toBe(true);
      const setup = await response.json();
      try {
        const fixture = await request.post('/test/e2e/conversation_fixture', {
          data: { account_id: setup.account_id, count: 1, title: 'Completion readiness' },
        });
        expect(fixture.ok()).toBe(true);
        const { chat_id: chatId } = await fixture.json();
        await page.goto('/login');
        await page.getByLabel(/email/i).fill(setup.primary_user.email);
        await page.getByLabel(/password/i).fill(setup.password);
        await page.getByRole('button', { name: /log in/i }).click();
        await expect(page).not.toHaveURL(/\/login/);
        await page.goto(`/accounts/${setup.account_param}/chats/${chatId}`);
        await page.getByRole('button', { name: 'Completion handoff and review', exact: true }).click();
        const form = page.getByRole('form', { name: 'Submit completion handoff' });
        await expect(form).toBeVisible();
        for (const [label, value] of [
          ['What changed', 'Built the readiness feature'],
          ['Where the result is', 'PR 123'],
          ['What was checked', 'Desktop and phone checks'],
          ['Anything remaining', 'Nothing remaining'],
        ]) {
          await form.getByLabel(label, { exact: true }).fill(value);
        }
        const submitted = page.waitForResponse(
          (r) => r.url().endsWith('/work_completion') && r.request().method() === 'POST'
        );
        await form.getByRole('button', { name: 'Save handoff for review' }).click();
        expect((await submitted).status()).toBe(200);
        await expect(page.getByRole('region', { name: 'Saved completion handoff' })).toContainText('PR 123');
        await page.screenshot({ path: testInfo.outputPath('saved-handoff.png'), fullPage: true });
        const accepted = page.waitForResponse((r) => r.url().endsWith('/work_completion/accept'));
        await page.getByRole('button', { name: 'Accept, keep open', exact: true }).click();
        expect((await accepted).status()).toBe(200);
        await expect(page.getByText('Accepted. Conversation remains open.')).toBeVisible();
        const closed = page.waitForResponse((r) => r.url().endsWith('/work_completion/close'));
        await page.getByRole('button', { name: 'Retry safe closure', exact: true }).click();
        expect((await closed).status()).toBe(200);
        await expect(page.getByText('Accepted. Conversation archived.')).toBeVisible();
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
        await page.screenshot({ path: testInfo.outputPath('accepted-closed.png'), fullPage: true });
      } finally {
        testInfo.setTimeout(testInfo.timeout + 15_000);
        expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
      }
    });
  });
}
