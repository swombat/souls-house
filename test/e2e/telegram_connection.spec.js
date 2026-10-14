import { expect, test } from '@playwright/test';

// The owner's Telegram sign-in and status on the integrations page. No live
// Telegram and no connector: the setup writes the connection states the
// connector's events would produce.
test('the owner signs in to Telegram and sees the connection', async ({ page, request }, testInfo) => {
  const runId = `telegram-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, telegram: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/integrations`);

    const qrCard = page.getByRole('article').filter({ hasText: 'Telegram sign-in' });
    const qr = qrCard.getByRole('img', { name: 'Telegram sign-in QR code' });
    await expect(qr).toBeVisible();
    expect(await qr.getAttribute('src')).toMatch(/^data:image\/png;base64,/);
    expect(await qr.evaluate((image) => image.naturalWidth)).toBeGreaterThan(0);
    await expect(qrCard.getByText(/Link Desktop Device/)).toBeVisible();
    await expect(qrCard.getByTestId('telegram-qr-countdown')).toHaveText(/expires in [45]:\d\d/);
    const before = await qrCard.getByTestId('telegram-qr-countdown').textContent();
    await expect(qrCard.getByTestId('telegram-qr-countdown')).not.toHaveText(before, { timeout: 3000 });
    await expect(qrCard.getByRole('button', { name: 'Restart sign-in' })).toBeVisible();
    await expect(qrCard.getByRole('button', { name: 'Cancel', exact: true })).toBeVisible();

    const passwordCard = page.getByRole('article').filter({ hasText: 'Telegram password' });
    const password = passwordCard.getByLabel('Telegram password', { exact: true });
    await expect(password).toHaveAttribute('type', 'password');
    await expect(password).toHaveAttribute('autocomplete', 'current-password');
    await expect(passwordCard.getByText('Hint: the usual one')).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('telegram-desktop.png'), fullPage: true });
    await qrCard.screenshot({ path: testInfo.outputPath('telegram-desktop-qr.png') });
    await passwordCard.screenshot({ path: testInfo.outputPath('telegram-desktop-password.png') });

    const urlBefore = page.url();
    await password.fill('correct horse battery staple');
    const sent = page.waitForResponse((reply) => reply.url().endsWith('/login/password'));
    await passwordCard.getByRole('button', { name: 'Sign in' }).click();
    expect(await (await sent).json()).toEqual({ outcome: 'not_configured' });
    await expect(passwordCard.getByText(/connector is not set up on this house/)).toBeVisible();
    await expect(password).toHaveValue('');
    expect(page.url()).toBe(urlBefore);
    expect(await page.evaluate(() => JSON.stringify(window.history.state ?? null))).not.toContain('correct horse');

    // Anchored on the status: the phone sign-in also says "Telegram account".
    const connected = page.getByRole('article').filter({ has: page.getByTestId('telegram-status') });
    const status = connected.getByTestId('telegram-status');
    await expect(status).toContainText('Ada Example (@ada_example)');
    await expect(status).toContainText('2 of 3 chats synced');
    await expect(status).toContainText('New messages are paused');
    await expect(status).toContainText('Reason: 6,000 events waiting');
    const searchAll = connected.getByLabel(/Let residents search beyond the synced chats/);
    await expect(searchAll).not.toBeChecked();
    const saved = page.waitForResponse(
      (reply) => reply.request().method() === 'PATCH' && /\/service_connections\//.test(reply.url())
    );
    await searchAll.check();
    await saved;
    await page.reload();
    await expect(searchAll).toBeChecked();
    await connected.screenshot({ path: testInfo.outputPath('telegram-desktop-connected.png') });
    await expect(qr).toBeVisible();

    // A phone cannot scan its own screen: the number leads, and the QR is
    // folded away for signing in from a computer.
    await page.setViewportSize({ width: 390, height: 844 });
    await expect(qrCard.getByLabel('Phone number')).toBeVisible();
    const elsewhere = qrCard.getByTestId('telegram-qr-elsewhere');
    const foldedQr = elsewhere.getByRole('img', { name: 'Telegram sign-in QR code' });
    await expect(foldedQr).toBeHidden();
    await elsewhere.getByText('Signing in from a computer? Show the QR code').click();
    await expect(foldedQr).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('telegram-mobile.png'), fullPage: true });
    await qrCard.screenshot({ path: testInfo.outputPath('telegram-mobile-qr.png') });
    await connected.screenshot({ path: testInfo.outputPath('telegram-mobile-connected.png') });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);

    // The focused sign-in page: the same sign-in on its own, phone first. The
    // number goes by fetch only, never into history.
    await qrCard.getByTestId('telegram-sign-in-page-link').click();
    await expect(page).toHaveURL(/\/service_connections\/[^/]+\/login$/);
    const focused = page.getByTestId('telegram-sign-in-page');
    const phone = focused.getByLabel('Phone number');
    await expect(phone).toBeVisible();
    await expect(focused.getByText(/International format/)).toBeVisible();
    await phone.fill('+44 7700 900123');
    const asked = page.waitForResponse((reply) => reply.url().endsWith('/login/phone'));
    await focused.getByRole('button', { name: 'Send the code' }).click();
    expect((await (await asked).json()).outcome).toBe('not_configured');
    await expect(focused.getByText(/connector is not set up on this house, so nothing was sent/)).toBeVisible();
    expect(await page.evaluate(() => JSON.stringify(window.history.state ?? null))).not.toContain('7700');
    await page.screenshot({ path: testInfo.outputPath('telegram-mobile-sign-in-page.png'), fullPage: true });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
