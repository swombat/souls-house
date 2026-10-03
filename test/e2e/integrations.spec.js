import { expect, test } from '@playwright/test';

for (const role of ['primary_user', 'secondary_user']) {
  test(`integrations are unified for ${role}`, async ({ page, request }, testInfo) => {
    const runId = `integrations-${role}-${Date.now()}`;
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: runId, resident_dashboard: true, integrations: true },
    });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup[role].email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      const base = `/accounts/${setup.account_param}`;
      await page.goto(`${base}/residents/${setup.agents[0].id}/edit?tab=integrations`);
      const add = page.getByRole('link', { name: 'Add integration', exact: true });
      await expect(add).toHaveCount(1);
      await add.click();
      await expect(page).toHaveURL(/\/integrations/);
      await expect(page.getByRole('heading', { name: 'Integrations', exact: true })).toBeVisible();
      await expect(page.getByRole('heading', { name: 'Connect a new integration', exact: true })).toBeVisible();
      await expect(page.getByRole('heading', { name: 'Your integrations', exact: true })).toBeVisible();
      const shared = page.getByRole('article').filter({ hasText: 'Team files' });
      await expect(shared).toBeVisible();
      if (role === 'secondary_user') {
        await expect(shared.getByText('Managed by account admins')).toBeVisible();
        await expect(shared.getByRole('button', { name: 'Disconnect' })).toHaveCount(0);
        for (const control of await shared.getByRole('switch').all()) await expect(control).toBeDisabled();
        await expect(page.getByRole('heading', { name: 'member/project', exact: true })).toBeVisible();
      } else {
        await expect(shared.getByRole('button', { name: 'Disconnect' })).toBeVisible();
      }
      await page.getByRole('button', { name: 'User account menu', exact: true }).click();
      // Integrations moved under Account Settings; the menu keeps a single way in.
      await expect(page.getByRole('menuitem', { name: 'Account Settings', exact: true })).toHaveCount(1);
      await expect(page.getByRole('menuitem', { name: 'Integrations', exact: true })).toHaveCount(0);
      await expect(page.getByRole('menuitem', { name: /Personal Services|Account Services/ })).toHaveCount(0);
      await page.keyboard.press('Escape');
      await expect(page.getByRole('menu')).toHaveCount(0);
      await page.screenshot({ path: testInfo.outputPath(`${role}-desktop.png`), fullPage: true });
      await page.setViewportSize({ width: 390, height: 844 });
      await page.screenshot({ path: testInfo.outputPath(`${role}-mobile.png`), fullPage: true });
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      for (const legacy of ['personal_services', 'services']) {
        await page.goto(`${base}/${legacy}?connect=github`);
        await expect(page).toHaveURL(/\/integrations\?connect=github/);
        await expect(page.getByRole('heading', { name: 'Connect GitHub repository', exact: true })).toBeVisible();
      }
      await expect(page.getByLabel('Integration scope')).toHaveCount(0);
      await page.goto(`${base}/integrations?connect=google_workspace`);
      if (role === 'primary_user') {
        await expect(page.getByRole('radio', { name: /Just me/ })).toBeChecked();
        await page.getByRole('radio', { name: /The whole account/ }).check();
        await expect(page.getByRole('radio', { name: /The whole account/ })).toBeChecked();
      } else {
        await expect(page.getByLabel('Integration scope')).toHaveCount(0);
      }
      const connect = page.getByRole('button', { name: /^Connect / });
      const card = await page.locator('.rounded-xl.bg-card').filter({ has: connect }).boundingBox();
      for (const action of [page.getByRole('link', { name: 'Cancel', exact: true }), connect]) {
        const box = await action.boundingBox();
        expect(box.x).toBeGreaterThanOrEqual(card.x);
        expect(box.x + box.width).toBeLessThanOrEqual(card.x + card.width);
      }
      await page.screenshot({ path: testInfo.outputPath(`${role}-connect.png`), fullPage: true });
    } finally {
      expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
    }
  });
}
