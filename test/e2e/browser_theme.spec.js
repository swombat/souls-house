import { expect, test } from '@playwright/test';

test.use({ viewport: { width: 360, height: 740 }, colorScheme: 'dark' });

async function expectTheme(page, theme) {
  const meta = page.locator('meta[name="theme-color"]');
  await expect(meta).toHaveCount(1);
  await expect(meta).toHaveAttribute('content', theme === 'dark' ? '#0a0a0a' : '#ffffff');
  await expect(page.locator('html')).toHaveCSS('color-scheme', theme);
}

test('browser colour follows system changes on the login page', async ({ page }) => {
  await page.goto('/login');
  await expectTheme(page, 'dark');
  await page.emulateMedia({ colorScheme: 'light' });
  await expectTheme(page, 'light');
  await page.emulateMedia({ colorScheme: 'dark' });
  await expectTheme(page, 'dark');
});

test('browser colour follows saved theme, live selection, reload and navigation', async ({
  page,
  request,
}, testInfo) => {
  let setup;
  try {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `theme-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    // The minimal E2E fixture has no profile names; updates require both.
    const profile = await page.request.patch('/user', {
      data: { user: { first_name: 'Theme', last_name: 'Tester' } },
    });
    expect(profile.ok()).toBe(true);

    async function selectTheme(label) {
      await page.getByRole('button', { name: 'User account menu' }).click();
      const saved = page.waitForResponse(
        (response) => response.url().endsWith('/user') && response.request().method() === 'PATCH'
      );
      await page.getByRole('menuitem', { name: new RegExp(`^${label} theme`) }).click();
      expect((await saved).ok()).toBe(true);
    }

    await selectTheme('Light');
    await expectTheme(page, 'light'); // Explicit preference overrides dark OS.
    await page.reload();
    await expectTheme(page, 'light');
    await selectTheme('Dark');
    await expectTheme(page, 'dark');
    await page.emulateMedia({ colorScheme: 'light' });
    await expectTheme(page, 'dark'); // Explicit preference still wins.
    await page.reload();
    await expectTheme(page, 'dark');
    await page.getByRole('button', { name: 'User account menu' }).click();
    await page.getByRole('menuitem', { name: 'Change Password', exact: true }).click();
    await expect(page).toHaveURL(/password/);
    await expectTheme(page, 'dark');
    // Chat uses a fixed viewport shell, so its transparent navbar cannot rely
    // on the body painting behind it. Exercise dark app + light OS as well.
    await page.goto(`/accounts/${setup.account_id}/chats`);
    await expectTheme(page, 'dark');
    const shell = page.locator('.chat-viewport');
    const darkBackground = await page.locator('body').evaluate((body) => getComputedStyle(body).backgroundColor);
    await expect(shell).toHaveCSS('background-color', darkBackground);
    await page.screenshot({ path: testInfo.outputPath('dark-chat-navbar.png') });
    await selectTheme('System');
    await expectTheme(page, 'light');
    await expect(shell).toHaveCSS('background-color', 'oklch(1 0 0)');
    await page.emulateMedia({ colorScheme: 'dark' });
    await expectTheme(page, 'dark');
    await expect(shell).toHaveCSS('background-color', darkBackground);
  } finally {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
