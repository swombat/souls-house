import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test(`helper lifecycle is visible, private and recoverable (${mobile ? 'mobile' : 'desktop'})`, async ({
    page,
    request,
  }, testInfo) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `helpers-${Date.now()}-${mobile}` },
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
      await update({ helper_status: 'running', helper_count: 2 });
      const card = page.getByTestId('runtime-activity-card');
      const dot = (label) => card.getByRole('img', { name: `Helper 1 · ${label}`, exact: true });
      await expect(dot('Working')).toBeVisible();
      await expect(card.locator('details')).not.toHaveAttribute('open', '');
      const colour = await dot('Working').evaluate((el) => getComputedStyle(el).backgroundColor);
      await expect(dot('Working')).toHaveClass(/pulsing/);
      await expect(dot('Working')).not.toHaveCSS('animation-name', 'none');
      await page.emulateMedia({ reducedMotion: 'reduce' });
      await expect(dot('Working')).toHaveCSS('animation-name', 'none');
      await page.emulateMedia({ reducedMotion: 'no-preference' });
      await update({ helper_status: 'completed' });
      await expect(dot('Completed')).not.toHaveClass(/pulsing/);
      await update({ helper_status: 'running' });
      await expect(dot('Working')).toHaveClass(/pulsing/);
      await expect(dot('Working')).toHaveCSS('background-color', colour);
      await update({ stream_gap: true });
      await expect(dot('Status unconfirmed')).not.toHaveClass(/pulsing/);
      await page.reload();
      await expect(dot('Status unconfirmed')).toBeVisible();
      await update({ helper_status: 'running', helper_count: 35 });
      await expect(card.locator('summary').getByText('+3 more')).toBeVisible();
      await expect(card.locator('summary').getByRole('img')).toHaveCount(32);
      await card.locator('summary').click();
      await expect(card.getByRole('region', { name: 'Helper details' })).toBeVisible();
      await expect(card.getByText('Helpers started this turn', { exact: true })).toBeVisible();
      await expect(card.getByText('synthetic-model').first()).toBeVisible();
      expect(await card.textContent()).not.toContain('synthetic-child');
      expect(await card.textContent()).not.toContain('synthetic-parent');
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth)).toBe(true);
      await card.screenshot({ path: testInfo.outputPath('helpers-expanded.png') });
      await update({ complete: true });
      await expect(card.locator('details')).not.toHaveAttribute('open', '');
      await expect(dot('Status unconfirmed')).not.toHaveClass(/pulsing/);
      await page.reload();
      await expect(dot('Status unconfirmed')).toBeVisible();
      await card.screenshot({ path: testInfo.outputPath('helpers-finished.png') });

      // Turning narration off during a run must remove helpers, not just hide names.
      runId = undefined;
      await update({ helper_status: 'running' });
      const activeCard = page.getByTestId('runtime-activity-card').filter({ hasText: 'is working' });
      await expect(activeCard.getByRole('img', { name: 'Helper 1 · Working', exact: true })).toBeVisible();
      await update({ hide_helpers: true, helper_status: 'completed' });
      await expect(activeCard.getByRole('img')).toHaveCount(0);
      await page.reload();
      await expect(page.getByTestId('runtime-activity-card').getByRole('img')).toHaveCount(0);
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
}
