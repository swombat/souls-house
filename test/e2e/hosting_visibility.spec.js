import { expect, test } from '@playwright/test';

// #590 moved the Hosting tab behind site admin and put clamping and an
// unhealthy-only status line on Settings. This walks a resident's edit page
// as each kind of person: the account owner, an ordinary member, and a site
// admin who isn't in the account at all.

const shot = (name) => `test-results/hosting-visibility-${name}.png`;

async function login(page, email, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

test.describe('who sees the Hosting tab', () => {
  let setup;
  let unhealthy;
  let healthy;
  const runId = `hosting-visibility-${Date.now()}`;

  test.beforeAll(async ({ request }) => {
    const response = await request.post('/test/e2e/setup', { data: { run_id: runId, hosting_visibility: true } });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    unhealthy = setup.agents.find((agent) => agent.name === 'E2E Researcher');
    healthy = setup.agents.find((agent) => agent.name === 'E2E Critic');
  });

  test.afterAll(async ({ request }) => {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  });

  test('the owner gets Settings with clamping and Restart, and no Hosting', async ({ page }) => {
    await login(page, setup.primary_user.email, setup.password);
    await page.goto(unhealthy.edit_url);

    await expect(page.getByRole('button', { name: 'Settings', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Hosting', exact: true })).toHaveCount(0);

    await page.getByRole('button', { name: 'Settings', exact: true }).click();
    const status = page.getByTestId('runtime-status');
    await expect(status).toBeVisible();
    await expect(status.getByText("E2E Researcher isn't responding right now.")).toBeVisible();
    await expect(status.getByRole('button', { name: 'Restart', exact: true })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Claude Code clamping' })).toBeVisible();
    await page.screenshot({ path: shot('owner-unhealthy'), fullPage: true });

    // An old link to the Hosting tab lands on Settings.
    await page.goto(`${unhealthy.edit_url}?tab=hosting`);
    await expect(page.getByRole('heading', { name: 'Claude Code clamping' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Identity filesystem' })).toHaveCount(0);

    // Hidden is not the only guard: the endpoints refuse the owner too.
    const diagnostics = await page.request.get(`${unhealthy.edit_url.replace(/\/edit$/, '')}/hosting_diagnostics`);
    expect(diagnostics.status()).toBe(403);
    const preview = await page.request.get(
      `${unhealthy.edit_url.replace(/\/edit$/, '')}/hosting_diagnostics/file_preview?path=soul.md`,
    );
    expect(preview.status()).toBe(403);

    // A healthy resident has no status line at all.
    await page.goto(`${healthy.edit_url}?tab=settings`);
    await expect(page.getByRole('heading', { name: 'AI model' })).toBeVisible();
    await expect(page.getByTestId('runtime-status')).toHaveCount(0);
    await page.screenshot({ path: shot('owner-healthy'), fullPage: true });

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto(`${unhealthy.edit_url}?tab=settings`);
    await expect(page.getByTestId('runtime-status')).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: shot('owner-unhealthy-mobile'), fullPage: true });
  });

  test('a member sees the status line but no Restart and no Hosting', async ({ page }) => {
    await login(page, setup.secondary_user.email, setup.password);
    await page.goto(`${unhealthy.edit_url}?tab=settings`);

    await expect(page.getByRole('button', { name: 'Hosting', exact: true })).toHaveCount(0);
    const status = page.getByTestId('runtime-status');
    await expect(status).toBeVisible();
    await expect(status.getByText('The account owner can restart them from this page.')).toBeVisible();
    await expect(status.getByRole('button', { name: 'Restart', exact: true })).toHaveCount(0);
    await page.screenshot({ path: shot('member-unhealthy'), fullPage: true });

    const diagnostics = await page.request.get(`${unhealthy.edit_url.replace(/\/edit$/, '')}/hosting_diagnostics`);
    expect(diagnostics.status()).toBe(403);
  });

  test('a site admin still has the Hosting tab', async ({ page }) => {
    await login(page, setup.admin_user.email, setup.password);
    await page.goto(unhealthy.edit_url);

    const hosting = page.getByRole('button', { name: 'Hosting', exact: true });
    await expect(hosting).toBeVisible();
    await hosting.click();
    await expect(page.getByRole('heading', { name: 'Identity filesystem' })).toBeVisible();
    await page.screenshot({ path: shot('admin-hosting'), fullPage: true });
  });
});
