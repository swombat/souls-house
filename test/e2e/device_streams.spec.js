import { expect, test } from '@playwright/test';

test('account services leads to account-scoped device controls and separate recovery', async ({ page, request }) => {
  const runId = `device-streams-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();

  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/services`);
    await expect(page.getByRole('heading', { name: 'Connect a new integration' })).toBeVisible();
    await page.screenshot({ path: 'test-results/device-integrations-desktop.png', fullPage: true });
    await page.getByRole('link', { name: /Polar H10 \/ RR stream/ }).click();
    await expect(page).toHaveURL(`/accounts/${setup.account_param}/device_streams`);
    await expect(page.locator('select[name=account_id]')).toHaveCount(0);
    await expect(page.getByRole('navigation', { name: 'Account settings' })).toBeVisible();
    await page.screenshot({ path: 'test-results/device-streams-index-desktop.png', fullPage: true });
    await page.getByLabel('Stream name').fill('Synthetic H10');
    await page.getByRole('button', { name: 'Create disabled stream' }).click();
    await expect(page.getByRole('heading', { name: 'Synthetic H10' })).toBeVisible();
    await expect(page).toHaveURL(new RegExp(`/accounts/${setup.account_param}/device_streams/[a-f0-9]+$`));
    await expect(page.getByLabel('Enable device ingestion')).not.toBeChecked();
    await expect(page.getByRole('checkbox', { name: /E2E Researcher/ })).toBeVisible();
    await page.getByRole('checkbox', { name: /E2E Researcher/ }).check();
    await page.getByLabel('Enable device ingestion').check();
    await page.getByRole('button', { name: 'Save readers and ingestion choice' }).click();
    await expect(page.getByRole('checkbox', { name: /E2E Researcher/ })).toBeChecked();
    await expect(page.getByText('Ingesting', { exact: true })).toBeVisible();
    await page.screenshot({ path: 'test-results/device-stream-controls-desktop.png', fullPage: true });

    // The one-time token must not survive in browser history (Inertia keeps page props in history.state).
    await page.getByRole('button', { name: 'Create append-only device credential' }).click();
    const issued = page.getByTestId('issued-credential');
    await expect(issued).toBeVisible();
    const token = (await issued.locator('pre').textContent()).trim();
    expect(token).toMatch(/^shd_[0-9a-f]{64}$/);
    await expect(page.getByRole('button', { name: 'Revoke device' })).toHaveCount(1);
    expect(JSON.stringify(await page.evaluate(() => window.history.state))).not.toContain(token);

    // Leave through an Inertia link, then Back: restored from history.state.
    await page
      .getByRole('navigation', { name: 'Account settings' })
      .getByRole('link', { name: 'Integrations' })
      .click();
    await expect(page.getByRole('heading', { name: 'Connect a new integration' })).toBeVisible();
    await page.goBack();
    await expect(page.getByRole('heading', { name: 'Synthetic H10' })).toBeVisible();
    await expect(page.getByTestId('issued-credential')).toHaveCount(0);
    expect(await page.content()).not.toContain(token);

    // Fresh token, then leave through a full page load, then Back.
    await page.getByRole('button', { name: 'Create append-only device credential' }).click();
    await expect(page.getByTestId('issued-credential')).toBeVisible();
    const secondToken = (await page.getByTestId('issued-credential').locator('pre').textContent()).trim();
    expect(secondToken).toMatch(/^shd_[0-9a-f]{64}$/);
    expect(secondToken).not.toBe(token);
    await expect(page.getByRole('button', { name: 'Revoke device' })).toHaveCount(2);
    await page.goto('/device_streams');
    await page.goBack();
    await expect(page.getByRole('heading', { name: 'Synthetic H10' })).toBeVisible();
    await expect(page.getByTestId('issued-credential')).toHaveCount(0);
    expect(await page.content()).not.toContain(secondToken);
    expect(JSON.stringify(await page.evaluate(() => window.history.state))).not.toContain(secondToken);

    await page.setViewportSize({ width: 390, height: 844 });
    await page.screenshot({ path: 'test-results/device-stream-controls-mobile.png', fullPage: true });
    await page.goto('/device_streams');
    await page.getByRole('link', { name: 'Synthetic H10' }).click();
    await expect(page.getByRole('button', { name: 'Create append-only device credential' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Save readers and ingestion choice' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Delete all sessions and close stream' })).toBeVisible();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
