import { expect, test } from '@playwright/test';

// The admission project runs after chromium: this test deliberately changes a
// global setting and must never race other files' synthetic account creation.
test('account cap closes ordinary admission but preserves the admin exception', async ({
  page,
  request,
  browser,
}, testInfo) => {
  const runId = `capacity-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const ordinary = await browser.newContext({ baseURL: testInfo.project.use.baseURL });
  const visitor = await ordinary.newPage();
  let oldLimit;
  async function login(target, user) {
    await target.goto('/login');
    await target.getByLabel(/email/i).fill(user.email);
    await target.getByLabel(/password/i).fill(setup.password);
    await target.getByRole('button', { name: /log in/i }).click();
    await expect(target).toHaveURL(/\/$/);
  }
  async function saveLimit(value) {
    await page.goto('/admin/settings');
    await page.getByLabel('Maximum accounts').fill(String(value));
    const saved = page.waitForResponse(
      (res) => res.url().endsWith('/admin/settings') && res.request().method() === 'PATCH'
    );
    await page.getByRole('button', { name: 'Save Settings' }).click();
    expect((await saved).status()).toBeLessThan(400);
    await page.reload();
    await expect(page.getByLabel('Maximum accounts')).toHaveValue(String(value));
  }
  try {
    await login(page, setup.admin_user);
    await page.goto('/admin/settings');
    oldLimit = Number(await page.getByLabel('Maximum accounts').inputValue());
    await saveLimit(0);
    await page.screenshot({ path: testInfo.outputPath('account-cap-setting.png') });
    await visitor.goto('/signup');
    await expect(visitor).toHaveURL(/\/$/);
    await visitor.goto('/login');
    await expect(visitor.getByText('New signups are currently closed.')).toBeVisible();
    await expect(visitor.getByRole('link', { name: 'Sign up', exact: true })).toHaveCount(0);
    await login(visitor, setup.primary_user);
    await visitor.goto('/accounts/new');
    await expect(visitor).toHaveURL(/\/$/);
    await visitor.getByRole('button', { name: 'User account menu' }).click();
    await visitor.getByRole('menuitem', { name: /^Account(?! Settings)/ }).click();
    await expect(visitor.getByRole('menuitem', { name: 'New Account', exact: true })).toHaveAttribute(
      'aria-disabled',
      'true'
    );
    await page.goto('/accounts/new');
    await expect(page.getByRole('button', { name: 'Create Account', exact: true })).toBeEnabled();
    await saveLimit(oldLimit);
    await visitor.goto('/accounts/new');
    await expect(visitor.getByRole('button', { name: 'Create Account', exact: true })).toBeEnabled();
  } finally {
    if (oldLimit !== undefined) await saveLimit(oldLimit);
    await ordinary.close();
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
