import { expect, test } from '@playwright/test';

// Pixel 10 Pro XL in portrait: 412 CSS px wide. With the on-screen keyboard open the layout viewport shrinks
// (interactive-widget=resizes-content) to roughly 450 px. The icon results must still be reachable.
test.use({ viewport: { width: 412, height: 915 }, hasTouch: true, isMobile: true });

test('tag editor icon search stays usable with the phone keyboard open', async ({ page, request }, testInfo) => {
  const response = await request.post('/test/e2e/setup', { data: { run_id: `visual-tags-keyboard-${Date.now()}` } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/accounts/${setup.account_param}/interface`);
    await page.getByRole('button', { name: 'Add tag', exact: true }).click();
    const form = page.getByRole('form', { name: 'Add visual tag', exact: true });

    // Keyboard up while typing the label: the icons below can still be scrolled to.
    await form.getByLabel('Label', { exact: true }).fill('Questions');
    await page.setViewportSize({ width: 412, height: 450 });
    const chatCircle = form.getByRole('button', { name: 'Chat Circle', exact: true });
    await chatCircle.scrollIntoViewIfNeeded();
    await expect(chatCircle).toBeInViewport();

    // Keyboard up while searching: results appear right under the search box without hiding the keyboard.
    const search = form.getByRole('searchbox', { name: 'Search icons' });
    await search.focus();
    await search.fill('quest');
    const question = form.getByRole('button', { name: 'Question', exact: true });
    await expect(question).toBeInViewport();
    await expect(search).toBeInViewport();
    await page.screenshot({ path: testInfo.outputPath('keyboard-search.png') });
    await question.click();
    await expect(form.getByLabel('Current icon: Question')).toBeVisible();

    // Save stays reachable with the keyboard up.
    const save = form.getByRole('button', { name: 'Add tag', exact: true });
    await expect(save).toBeInViewport();
    await save.click();
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Edit Questions' })).toBeVisible();
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } })).ok()).toBe(true);
  }
});
