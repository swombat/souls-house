import { expect, test } from '@playwright/test';

test('two WhatsApp connections can be named, reset and safely distinguished', async ({ page, request }, testInfo) => {
  const runId = `connection-names-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, connection_names: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    const url = `/accounts/${setup.account_param}/integrations`;
    await page.goto(url);
    const personal = page.getByRole('article').filter({ hasText: '•••• 0123' });
    const work = page.getByRole('article').filter({ hasText: '•••• 0456' });
    await expect(personal).toHaveCount(1);
    await expect(work).toHaveCount(1);
    for (const [row, name] of [
      [personal, 'Personal'],
      [work, 'Work'],
    ]) {
      await row.getByRole('button', { name: /^Show details/ }).click();
      await expect(row.getByLabel('Connection name', { exact: true })).toHaveValue('');
      await row.getByLabel('Connection name', { exact: true }).fill(name);
      await row.getByRole('button', { name: 'Save', exact: true }).click();
      await expect(row.getByRole('heading', { name, exact: true })).toBeVisible();
    }
    await page.reload();
    await expect(personal.getByRole('heading', { name: 'Personal', exact: true })).toBeVisible();
    await expect(work.getByRole('heading', { name: 'Work', exact: true })).toBeVisible();
    await personal.getByRole('button', { name: 'Show details for Personal', exact: true }).click();
    await personal.getByLabel('Connection name', { exact: true }).fill('Unsubmitted');
    await personal.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(personal.getByLabel('Connection name', { exact: true })).toHaveValue('Personal');

    let confirmation;
    page.once('dialog', async (dialog) => {
      confirmation = dialog.message();
      await dialog.dismiss();
    });
    await personal.getByRole('button', { name: 'Disconnect', exact: true }).click();
    expect(confirmation).toContain('Personal');
    expect(confirmation).toContain('WhatsApp');
    expect(confirmation).toContain('•••• 0123');
    expect(confirmation).not.toContain('447700900123');
    await expect(work.getByRole('heading', { name: 'Work', exact: true })).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('named-connections-desktop.png'), fullPage: true });

    await personal.getByLabel('Connection name', { exact: true }).fill('');
    await personal.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(personal.getByRole('heading', { name: '•••• 0123', exact: true })).toBeVisible();
    await expect(work.getByRole('heading', { name: 'Work', exact: true })).toBeVisible();
    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: testInfo.outputPath('named-connections-mobile.png'), fullPage: true });
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
