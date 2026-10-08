import { expect, test } from '@playwright/test';

// The Site Admin menu's Deploy entry opens a submenu of the deploy workflows.
// Pressing one confirms, dispatches, and lands on the Deploys page. The test
// house has no deploy token, so the dispatch is refused server-side and no
// GitHub call is made; the landing is what's under test.
test('site admin starts a deploy from the menu and lands on the Deploys page', async ({ page, request }) => {
  const runId = `deploy-menu-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, admin_account_list: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();

  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.admin_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).toHaveURL(/\/$/);

  await page.getByRole('button', { name: /site admin/i }).click();
  await page.getByTestId('deploy-submenu').hover();
  const submenu = page.getByRole('menu').last();
  await expect(submenu.getByRole('menuitem', { name: 'Deployments' })).toBeVisible();
  for (const name of ['Deploy Rails', 'Rebuild residents', 'Update Chaos', 'Deploy both']) {
    await expect(submenu.getByRole('menuitem', { name })).toBeVisible();
  }
  await page.screenshot({ path: 'test-results/site-admin-deploy-menu.png' });

  page.once('dialog', (dialog) => {
    expect(dialog.message()).toContain('Deploy Rails');
    dialog.accept();
  });
  await submenu.getByRole('menuitem', { name: 'Deploy Rails' }).click();
  await expect(page).toHaveURL(/\/admin\/deploys$/);
  await expect(page.getByRole('heading', { level: 1, name: 'Deploy' })).toBeVisible();
  await expect(page.getByRole('main').getByText('No deploy token configured', { exact: true })).toBeVisible();
});
