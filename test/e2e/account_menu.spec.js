import { expect, test } from '@playwright/test';

for (const width of [360, 1280]) {
  test(`account menu uses one visible panel at ${width}px without duplicate entries`, async ({
    page,
    request,
  }, testInfo) => {
    const runId = `account-menu-${Date.now()}`;
    const response = await request.post('/test/e2e/setup', { data: { run_id: runId, single_account: true } });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    const accountName = `Second ${runId}`;
    try {
      await page.setViewportSize({ width, height: 800 });
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.primary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      await page.getByRole('button', { name: 'User account menu' }).click();
      for (const theme of ['Light', 'Dark', 'System']) {
        await expect(page.getByRole('menuitem', { name: new RegExp(`^${theme} theme`) })).toBeVisible();
      }
      await page.getByRole('menuitem', { name: /^Dark theme/ }).click();
      await expect(page.locator('html')).toHaveClass(/dark/);
      await page.getByRole('button', { name: 'User account menu' }).click();
      const newAccount = page.getByRole('menuitem', { name: 'New Account', exact: true });
      await expect(newAccount).toHaveCount(1);
      await newAccount.click();
      await expect(page).toHaveURL(/\/accounts\/new$/);
      await page.getByLabel('Account Name').fill(accountName);
      await page.getByRole('button', { name: 'Create Account', exact: true }).click();
      await expect(page).toHaveURL(/\/accounts\/[^/]+\/residents\/new$/);

      await page.getByRole('button', { name: 'User account menu' }).click();
      await expect(newAccount).toHaveCount(0);
      await page.getByRole('menuitem', { name: `Account ${accountName}`, exact: true }).click();
      const back = page.getByRole('menuitem', { name: 'Back', exact: true });
      await expect(back).toBeFocused();
      await expect(page.getByRole('menu')).toHaveCount(1);
      const bounds = await page.getByRole('menu').boundingBox();
      expect(bounds.x).toBeGreaterThanOrEqual(0);
      expect(bounds.x + bounds.width).toBeLessThanOrEqual(width);
      await back.press('Enter');
      const accounts = page.getByRole('menuitem', { name: `Account ${accountName}`, exact: true });
      await expect(accounts).toBeFocused();
      await accounts.press('Enter');
      await expect(back).toBeFocused();
      await back.press('Escape');
      await expect(page.getByRole('button', { name: 'User account menu' })).toBeFocused();
      await page.getByRole('button', { name: 'User account menu' }).click();
      await expect(back).toHaveCount(0);
      await accounts.click();
      await expect(newAccount).toHaveCount(1);
      await expect(newAccount).toBeEnabled();
      await page.screenshot({ path: testInfo.outputPath('account-submenu.png') });
      await newAccount.click();
      await expect(page).toHaveURL(/\/accounts\/new$/);
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
    }
  });
}
