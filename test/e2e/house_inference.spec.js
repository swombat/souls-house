import { expect, test } from '@playwright/test';

test('house funding is explicit, explains privacy and enforces one resident with no personal key', async ({
  page,
  request,
}) => {
  const runId = `house-funding-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const residents = setup.agents.filter((agent) => ['E2E Researcher', 'E2E Critic'].includes(agent.name));
    expect(residents).toHaveLength(2);
    const selectHouse = async (resident) => {
      await page.goto(`${resident.edit_url}?tab=settings`);
      await page.getByRole('button', { name: 'openrouter/auto', exact: true }).click();
      await page.getByRole('option', { name: /DeepSeek V4.1 Flash · On the house/ }).click();
    };
    await selectHouse(residents[0]);
    const allowance = page.getByRole('region', { name: 'House inference allowance' });
    await expect(allowance).toContainText('One funded resident per user');
    await expect(allowance).toContainText('Fireworks’ US endpoint');
    await page.getByRole('button', { name: 'Update Resident', exact: true }).click();
    await expect(page).toHaveURL(/\/residents$/);
    await page.goto(`${residents[0].edit_url}?tab=settings`);
    await expect(allowance).toContainText('$10.00 remaining');
    await page.screenshot({ path: 'test-results/house-funding-desktop.png', fullPage: true });
    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: 'test-results/house-funding-mobile.png', fullPage: true });
    await selectHouse(residents[1]);
    await page.getByRole('button', { name: 'Update Resident', exact: true }).click();
    await expect(page).toHaveURL(/\/edit/);
    // Inertia preserves the Settings tab on validation errors.
    await expect(page.getByText(/only one on-the-house resident is allowed/)).toBeVisible();
  } finally {
    const cleanup = await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
    expect(cleanup.ok()).toBe(true);
  }
});
