import { expect, test } from '@playwright/test';

for (const role of ['primary_user', 'secondary_user']) {
  test(`account settings navigation and permissions for ${role}`, async ({ page, request }, testInfo) => {
    const runId = `account-settings-${role}-${Date.now()}`;
    const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup[role].email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /log in/i }).click();
      await expect(page).toHaveURL(/\/$/);
      const base = `/accounts/${setup.account_param}`;
      await page.goto(`${base}/edit`);
      await expect(page).toHaveURL(new RegExp(`${base}$`));
      await page.getByLabel('Account name', { exact: true }).fill(`Reviewed ${role}`);
      await page.getByRole('button', { name: 'Save name', exact: true }).click();
      await expect(page.getByRole('button', { name: 'Save name', exact: true })).toBeDisabled();
      await page.reload();
      await expect(page.getByLabel('Account name', { exact: true })).toHaveValue(`Reviewed ${role}`);

      const nav = page.getByRole('navigation', { name: 'Account settings', exact: true });
      for (const [label, path] of [
        ['Model API keys', '/agent_api_keys'],
        ['Integrations', '/integrations'],
        ['Notices', '/notices'],
        ['Costs', '/costs'],
        ['General', ''],
      ]) {
        await nav.getByRole('link', { name: label, exact: true }).click();
        await expect(page).toHaveURL(new RegExp(`${base}${path}$`));
        await expect(nav.getByRole('link', { name: label, exact: true })).toHaveAttribute('aria-current', 'page');
      }

      await nav
        .getByRole('link', { name: / API$/, exact: false })
        .filter({ hasText: /house|Helix/i })
        .click();
      const internal = page.locator('details').filter({ hasText: 'Internal resident keys' });
      await expect(internal).not.toHaveAttribute('open', '');
      await internal.locator('summary').click();
      await expect(internal).toHaveAttribute('open', '');
      await expect(internal.getByRole('button')).toHaveCount(0);
      await page.screenshot({ path: testInfo.outputPath('api-desktop.png'), fullPage: true });

      await nav.getByRole('link', { name: 'Model API keys', exact: true }).click();
      const key = page.getByLabel('OpenRouter API key', { exact: true });
      if (role === 'secondary_user') {
        await expect(key).toBeDisabled();
        await expect(page.getByRole('button', { name: 'Save model API keys', exact: true })).toHaveCount(0);
      } else {
        await expect(key).toBeEnabled();
      }

      await page.setViewportSize({ width: 390, height: 844 });
      await nav.getByRole('button', { name: 'Model API keys', exact: true }).click();
      await page.getByRole('option', { name: 'General', exact: true }).click();
      await expect(page).toHaveURL(new RegExp(`${base}$`));
      await expect(nav.getByRole('button', { name: 'General', exact: true })).toBeVisible();
      expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
      await page.screenshot({ path: testInfo.outputPath('general-mobile.png'), fullPage: true });

      if (role === 'primary_user') {
        await page.setViewportSize({ width: 1280, height: 900 });
        const memberRow = page.getByRole('row').filter({ hasText: setup.secondary_user.email });
        page.once('dialog', (dialog) => dialog.accept());
        await memberRow.getByRole('button', { name: 'Remove', exact: true }).click();
        await expect(memberRow).toHaveCount(0);
        await page.getByRole('button', { name: 'Convert to personal account', exact: true }).click();
        await expect(page.getByText(/renamed after its remaining owner/)).toBeVisible();
        await page.getByRole('button', { name: 'Convert to Personal Account', exact: true }).click();
        await expect(page).toHaveURL(new RegExp(`${base}$`));
        await page.getByRole('button', { name: 'Convert to team account', exact: true }).click();
        await page.getByLabel('Team Name').fill('Restored team');
        await page.getByRole('button', { name: 'Convert to Team Account', exact: true }).click();
        await expect(page).toHaveURL(new RegExp(`${base}$`));
        await expect(page.getByLabel('Account name', { exact: true })).toHaveValue('Restored team');
      }
    } finally {
      expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
    }
  });
}
