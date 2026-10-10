import { expect, test } from '@playwright/test';

// iPhone-sized: the account name next to the logo is mostly for this width.
test.use({ viewport: { width: 390, height: 844 }, colorScheme: 'light' });

async function saveSettings(page) {
  const saved = page.waitForResponse(
    (response) => response.url().endsWith('/user') && response.request().method() === 'PATCH'
  );
  await page.getByRole('button', { name: 'Save Changes' }).click();
  expect((await saved).status()).toBeLessThan(400);
}

test('personal tint, account logo colour and account name in the navbar', async ({ page, request }, testInfo) => {
  let setup;
  try {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `themes-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const profile = await page.request.patch('/user', {
      data: { user: { first_name: 'Theme', last_name: 'Tester' } },
    });
    expect(profile.ok()).toBe(true);

    // A long account name is cut with an ellipsis instead of pushing the menu off screen.
    const longName = 'Daniel, Lume and Mira and a rather long account name';
    const renamed = await page.request.patch(`/accounts/${setup.account_id}`, {
      data: { account: { name: longName } },
      maxRedirects: 0,
    });
    expect(renamed.status()).toBe(302);
    await page.goto(`/accounts/${setup.account_id}/chats`);
    const name = page.getByTestId('nav-account-name');
    await expect(name).toHaveText(longName);
    await expect(name).toHaveCSS('text-overflow', 'ellipsis');
    const box = await name.boundingBox();
    expect(box.x + box.width).toBeLessThan(390 * 0.75);
    await expect(page.getByRole('button', { name: 'User account menu' })).toBeInViewport();

    // The logo goes home; the account name goes straight to the account's chats.
    await expect(page.getByTestId('nav-home-logo')).toHaveAttribute('href', /^(https?:\/\/[^/]+)?\/$/);
    await expect(name).toHaveAttribute('href', new RegExp(`/accounts/${setup.account_id}/chats$`));

    // Default look is untouched.
    await expect(page.locator('body')).toHaveCSS('background-color', 'oklch(1 0 0)');
    const dot = page.locator('nav svg circle').first();
    // The default coral; theme.test.js checks this OKLCH value renders exactly #f15d61.
    const coral = /rgb\(241, 93, 97\)|oklch\(0\.6715 0\.1825 21\.87\)/;
    await expect(dot).toHaveCSS('fill', coral);

    // Account logo colour, set on the Interface page.
    await page.goto(`/accounts/${setup.account_id}/interface`);
    await page.getByRole('radio', { name: 'Teal' }).click();
    await expect(page.locator('html')).toHaveAttribute('data-account-colour', 'teal');
    await expect(dot).not.toHaveCSS('fill', coral);
    const tealLight = await dot.evaluate((el) => getComputedStyle(el).fill);
    await page.screenshot({ path: testInfo.outputPath('interface-teal-light.png') });

    // Personal tint, chosen in settings and kept after save and reload.
    await page.goto('/user/edit');
    await page.getByRole('radio', { name: 'Rose' }).click();
    await expect(page.locator('html')).toHaveCSS('--tint-h', '355');
    await saveSettings(page);
    await page.reload();
    await expect(page.locator('html')).toHaveAttribute('style', /--tint-h: 355/);
    const lightBackground = await page.locator('body').evaluate((body) => getComputedStyle(body).backgroundColor);
    expect(lightBackground).not.toBe('oklch(1 0 0)');
    await page.screenshot({ path: testInfo.outputPath('settings-rose-light.png'), fullPage: true });

    // Dark mode: same hue, deep background, the dot switches to its dark value.
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.goto(`/accounts/${setup.account_id}/chats`);
    await expect(page.locator('html')).toHaveCSS('color-scheme', 'dark');
    const darkBackground = await page.locator('body').evaluate((body) => getComputedStyle(body).backgroundColor);
    expect(darkBackground).not.toBe(lightBackground);
    expect(await dot.evaluate((el) => getComputedStyle(el).fill)).not.toBe(tealLight);
    await page.screenshot({ path: testInfo.outputPath('chats-rose-teal-dark.png') });

    // Back to default.
    await page.goto('/user/edit');
    await page.getByRole('radio', { name: 'Default' }).click();
    await saveSettings(page);
    await page.reload();
    await expect(page.locator('html')).not.toHaveAttribute('style', /--tint-h/);
  } finally {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
