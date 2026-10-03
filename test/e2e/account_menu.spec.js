import { expect, test } from '@playwright/test';

test('single-account users can create another account without duplicate menu entries', async ({
  page,
  request,
}, testInfo) => {
  const runId = `account-menu-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, single_account: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const accountName = `Second ${runId}`;
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
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
    await page.getByRole('menuitem', { name: `Account ${accountName}`, exact: true }).hover();
    await expect(newAccount).toHaveCount(1);
    await expect(newAccount).toBeEnabled();
    await page.screenshot({ path: testInfo.outputPath('account-submenu.png') });
    await newAccount.click();
    await expect(page).toHaveURL(/\/accounts\/new$/);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
