import { expect, test } from '@playwright/test';

const rowFor = (page, label) => page.getByText(label, { exact: true }).locator('xpath=ancestor::*[.//button][1]');

test('the Sub-agents tab grants standing permission and an allowlist from the account keys', async ({
  page,
  request,
}) => {
  const runId = `subagents-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId, subagent_settings: true } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const resident = setup.agents.find((agent) => agent.name === 'E2E Researcher');
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);

    await page.goto(`${resident.edit_url}?tab=subagents`);
    const enabled = page.getByLabel('Allow this resident to use sub-agents');
    await expect(enabled).not.toBeChecked();
    await expect(page.getByText('Allowed sub-agent models')).toHaveCount(0);
    await page.screenshot({ path: 'test-results/subagents-off.png', fullPage: true });

    await enabled.check();
    await expect(page.getByText('Allowed sub-agent models')).toBeVisible();
    const filter = page.getByPlaceholder('Filter by model, provider, or source');
    await filter.fill('sonnet');
    await rowFor(page, 'Claude Sonnet (latest)').getByRole('button', { name: 'Add' }).click();
    await filter.fill('deepseek v4 flash');
    await rowFor(page, 'DeepSeek V4 Flash').getByRole('button', { name: 'Add' }).click();
    await filter.fill('');
    await page.getByLabel('Provider').selectOption('openai');
    await page.getByPlaceholder('Model ID').fill('gpt-6.1-sol');
    await page.getByPlaceholder('Model ID').locator('xpath=..').getByRole('button', { name: 'Add' }).click();
    await expect(page.getByText('OpenAI · API key · custom ID')).toBeVisible();
    await page.screenshot({ path: 'test-results/subagents-on.png', fullPage: true });

    await page.getByRole('button', { name: 'Update Resident' }).click();
    await expect(page).toHaveURL(/\/residents$/);

    await page.goto(`${resident.edit_url}?tab=subagents`);
    await expect(page.getByLabel('Allow this resident to use sub-agents')).toBeChecked();
    await expect(page.getByText('Claude Sonnet (latest)', { exact: true })).toBeVisible();
    await expect(page.getByText('Claude subscription', { exact: false }).first()).toBeVisible();
    await expect(page.getByText('gpt-6.1-sol', { exact: true })).toBeVisible();
    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await page.screenshot({ path: 'test-results/subagents-mobile.png', fullPage: true });
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
