import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test(`quiet turns distinguish silence, contact and a reply (${mobile ? 'mobile' : 'desktop'})`, async ({
    page,
    request,
  }, testInfo) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `silence-${Date.now()}-${mobile}` },
    });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      if (mobile) await page.setViewportSize({ width: 390, height: 844 });
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /sign in|log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      const fixture = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1 },
      });
      expect(fixture.ok()).toBe(true);
      const { chat_id: chatId } = await fixture.json();
      await page.goto(`/accounts/${setup.account_id}/chats/${chatId}`);
      let runId;
      const update = async (data) => {
        const result = await request.post('/test/e2e/runtime_activity', {
          data: { chat_id: chatId, runtime_run_id: runId, ...data },
        });
        expect(result.ok()).toBe(true);
        runId = (await result.json()).runtime_run_id;
      };
      await update({ silence_seconds: 125 });
      const card = page.getByTestId('runtime-activity-card');
      await expect(card.getByText(/2 min since run start · no resident post yet/)).toBeVisible();
      await expect(card.getByText(/runtime active/)).toBeVisible();
      await expect(card.locator('details')).not.toHaveAttribute('open', '');
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
      await card.screenshot({ path: testInfo.outputPath('quiet-runtime.png') });
      await update({ stale_report: true });
      await expect(card.getByText(/runtime contact uncertain/)).toBeVisible();
      await update({ post_update: true });
      await expect(card.getByRole('status')).toHaveCount(0);
      await expect(page.getByText('Synthetic progress update.')).toBeVisible();
      await update({ complete: true, quiet_complete: true });
      await expect(card.getByRole('status')).toHaveCount(0);
      await expect(card.getByText('finished', { exact: true })).toBeVisible();
      runId = null;
      await update({ silence_seconds: 125, hide_helpers: true });
      const privateCard = page.locator(`[data-run-id="${runId}"]`);
      await expect(privateCard).toBeVisible();
      await expect(privateCard.getByRole('status')).toHaveCount(0);
      await update({ complete: true, quiet_complete: true });
      await expect(privateCard.getByText('finished', { exact: true })).toBeVisible();
      await expect(privateCard.getByRole('status')).toHaveCount(0);
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
}
