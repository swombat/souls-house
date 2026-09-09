import { expect, test } from '@playwright/test';

test('admin can inspect account usage, settings and empty states on desktop and mobile', async ({ page, request }) => {
  const runId = `admin-usage-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, deprecated: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();

  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.admin_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/admin/accounts?account_id=${setup.account_id}`);

    const overview = page.getByRole('region', { name: 'Account usage overview' });
    await expect(overview.getByRole('heading', { name: 'Residents (4)', exact: true })).toBeVisible();
    await expect(overview.getByRole('heading', { name: 'E2E Researcher', exact: true })).toHaveCount(0);
    await expect(overview.getByRole('checkbox', { name: 'Show disabled' })).not.toBeChecked();
    await overview.getByRole('checkbox', { name: 'Show disabled' }).check();
    await expect(overview.getByRole('heading', { name: 'E2E Researcher', exact: true })).toBeVisible();
    await expect(overview.getByRole('heading', { name: 'Integrations & AI access' })).toBeVisible();
    await expect(overview.getByRole('heading', { name: 'Last 10 runtime sessions' })).toBeVisible();
    await expect(overview.getByText('No conversations yet.')).toBeVisible();
    await expect(overview.getByRole('button', { name: 'Measure storage' })).toBeDisabled();
    await expect(overview.getByText('Deprecated · Unavailable', { exact: true })).toHaveCount(4);
    await expect(overview.getByRole('separator')).toHaveCount(1);
    await expect(overview.getByRole('link', { name: 'Edit', exact: true })).toHaveCount(0);
    await expect(overview.getByRole('button', { name: /^Disable E2E/ })).toHaveCount(0);
    await expect(overview.getByText('/ medium', { exact: true })).toHaveCount(4);
    await overview.getByLabel('Activity metric').selectOption('conversations');
    await expect(overview.getByRole('img', { name: /conversations over/ })).toBeVisible();

    const conversation = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 1, diagnostics: true },
    });
    expect(conversation.ok()).toBe(true);
    await overview.getByRole('button', { name: 'Refresh overview' }).click();
    await expect(overview.getByText('2 messages · 1 resident replies')).toBeVisible();
    await expect(overview.getByText('1 failed (historical)')).toBeVisible();
    await expect(overview.getByText('completed', { exact: true })).toBeVisible();
    await expect(overview.getByText('Message tokens: 120 in / 30 out')).toBeVisible();
    await page.screenshot({ path: 'test-results/admin-conversation-diagnostics-desktop.png', fullPage: true });

    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await overview.getByRole('button', { name: 'Refresh overview' }).click();
    await expect(overview.getByRole('heading', { name: 'Residents (4)', exact: true })).toBeVisible();

    await page.screenshot({ path: 'test-results/admin-conversation-diagnostics-mobile.png', fullPage: true });

    await page.goto(`/admin/accounts?account_id=${setup.empty_account_id}`);
    await expect(overview.getByText('No residents have been created in this account.')).toBeVisible();
    await expect(overview.getByText('No activity in this period.')).toBeVisible();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
