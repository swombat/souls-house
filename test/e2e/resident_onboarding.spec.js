import { expect, test } from '@playwright/test';

test('new residents default to house funding and missing credentials never strand a first hello', async ({
  page,
  request,
}, testInfo) => {
  const runId = `onboarding-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, missing_resident_credentials: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/residents/new`);
    await page.getByRole('button', { name: 'Begin', exact: true }).click();
    await page.getByLabel(/name/i).fill('Synthetic new resident');
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await page
      .getByRole('textbox', { name: 'Initial soul seed', exact: true })
      .fill('Synthetic seed, not a real birth');
    await page.getByRole('button', { name: 'Continue', exact: true }).click();
    await expect(page.getByRole('button', { name: /DeepSeek V4.1 Flash · On the house/ })).toBeVisible();
    await page.screenshot({ path: testInfo.outputPath('house-default.png') });
    const resident = setup.agents.find((agent) => agent.name === 'E2E Researcher');
    await page.goto(`/accounts/${setup.account_param}/residents/${resident.id}/onboarding`);
    await expect(page.getByRole('status')).toContainText('set up credentials');
    await expect(page.getByRole('link', { name: 'Edit E2E Researcher', exact: true })).toBeVisible();
    await expect(page.getByText('Synthetic raw provider exception')).toHaveCount(0);
    await page.screenshot({ path: testInfo.outputPath('orientation-credentials.png') });
    const fixture = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 0, resident_count: 1 },
    });
    const { chat_id: chatId } = await fixture.json();
    await page.goto(`/accounts/${setup.account_param}/chats/${chatId}`);
    const composer = page.getByTestId('message-composer').locator('textarea');
    await composer.fill('My first hello remains saved');
    await composer.press('Enter');
    await expect(page.getByText('My first hello remains saved', { exact: true })).toBeVisible();
    await expect(page.getByRole('status', { name: 'Resident setup' })).toContainText('set up credentials');
    await expect(page.getByTestId('runtime-activity-card')).toHaveCount(0);
    await page.getByRole('link', { name: 'Edit E2E Researcher', exact: true }).click();
    await expect(page).toHaveURL(/\/residents\/[^/]+\/edit$/);
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
