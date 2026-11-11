import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test.describe(`reported work status (${mobile ? 'mobile' : 'desktop'})`, () => {
    if (mobile) test.use({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
    test('declare, filter, observe a reply, and keep completed work visible', async ({ page, request }, testInfo) => {
      const response = await request.post('/test/e2e/setup', {
        data: { run_id: `work-status-${mobile}-${Date.now()}` },
      });
      expect(response.ok()).toBe(true);
      const setup = await response.json();
      try {
        const fixture = await request.post('/test/e2e/conversation_fixture', {
          data: { account_id: setup.account_id, count: 1, title: 'Notification readiness' },
        });
        expect(fixture.ok()).toBe(true);
        const { chat_id: chatId } = await fixture.json();
        await page.goto('/login');
        await page.getByLabel(/email/i).fill(setup.primary_user.email);
        await page.getByLabel(/password/i).fill(setup.password);
        await page.getByRole('button', { name: /log in/i }).click();
        await expect(page).not.toHaveURL(/\/login/);
        const base = `/accounts/${setup.account_param}`;
        await page.goto(`${base}/chats/${chatId}`);

        async function setStatus(from, to, reason = '') {
          await page.getByRole('button', { name: `Change work status: ${from}`, exact: true }).click();
          const form = page.getByRole('form', { name: 'Change work status', exact: true });
          await form.getByRole('combobox', { name: 'Status', exact: true }).selectOption(to);
          if (reason) await form.getByLabel(/Reason/).fill(reason);
          const saved = page.waitForResponse(
            (r) => r.url().endsWith('/work_status') && r.request().method() === 'PATCH'
          );
          await form.getByRole('button', { name: 'Save status', exact: true }).click();
          expect((await saved).status()).toBe(200);
          await expect(form).toHaveCount(0);
        }

        await setStatus('Not declared', 'needs_input', 'Which result should we publish?');
        await expect(
          page.getByRole('button', { name: 'Change work status: Needs your input', exact: true })
        ).toBeVisible();
        await page.screenshot({ path: testInfo.outputPath('needs-input.png'), fullPage: true });
        expect(
          (
            await request.post('/test/e2e/append_messages', {
              data: { chat_id: chatId, count: 1, prefix: 'Publish the first result' },
            })
          ).ok()
        ).toBe(true);
        await page.reload();
        await expect(page.getByText(/Human replied since/).first()).toBeVisible();
        await expect(
          page.getByRole('button', { name: 'Change work status: Needs your input', exact: true })
        ).toBeVisible();
        await setStatus('Needs your input', 'ready_for_review');
        await page.reload();
        await expect(
          page.getByRole('button', { name: 'Change work status: Ready for review', exact: true })
        ).toBeVisible();

        // The same filters must be reachable on phones, not just a hidden desktop sidebar.
        await page.goto(`${base}/chats/new?room=all`);
        const nav = mobile
          ? page.getByRole('navigation', { name: 'Recent conversations' })
          : page.locator('aside').first();
        if (mobile) await nav.locator('summary').filter({ hasText: 'Filter conversations' }).click();
        else await nav.getByTestId('chat-filter-trigger').click();
        const filter = mobile ? nav : page;
        await filter.getByRole('combobox', { name: 'Work status', exact: true }).selectOption('ready_for_review');
        await expect(page).toHaveURL(/work_status=ready_for_review/);
        await expect(nav.getByRole('link', { name: /Notification readiness/ })).toBeVisible();
        await page.screenshot({ path: testInfo.outputPath('status-filter.png'), fullPage: true });
        await page.keyboard.press('Escape');
        await nav.getByRole('link', { name: /Notification readiness/ }).click();
        await expect(page).toHaveURL(/work_status=ready_for_review/);
        await setStatus('Ready for review', 'completed', 'Result published and checked');
        // The active ready-for-review filter excludes it, but the default list must not.
        await page.goto(`${base}/chats/new?room=all`);
        await expect(nav.getByRole('link', { name: /Notification readiness/ })).toBeVisible();
        await expect(
          nav.getByRole('link', { name: /Notification readiness/ }).getByText('Completed', { exact: true })
        ).toBeVisible();
        expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
        await page.screenshot({ path: testInfo.outputPath('completed-listed.png'), fullPage: true });
      } finally {
        // Leave time to remove the synthetic account even after a failed assertion.
        testInfo.setTimeout(testInfo.timeout + 15_000);
        expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
      }
    });
  });
}
