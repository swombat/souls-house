import { expect, test } from '@playwright/test';

// #596: a group the bot was added to appears on the resident's Telegram
// settings switched off; the owner switches it on and the page says so.
test('the owner allows a Telegram group from the resident settings', async ({ page, request }, testInfo) => {
  const runId = `telegram-group-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const agent = setup.agents[0];
  for (const operation of ['prepare', 'group']) {
    const fixture = await request.post('/test/e2e/telegram_presentation_fixture', {
      data: { account_id: setup.account_id, agent_id: agent.id, operation },
    });
    expect(fixture.ok()).toBe(true);
  }

  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.primary_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
  await page.goto(`/accounts/${setup.account_param}/agents/${agent.id}/edit?tab=integrations`);
  await page.getByRole('button', { name: 'Settings', exact: true }).last().click();

  const groups = page.getByTestId('telegram-groups');
  await expect(groups).toContainText("spends a turn on this account's plan");
  const row = groups.getByTestId('telegram-group').filter({ hasText: 'E2E group' });
  await expect(row).toContainText('nothing from this group is read or kept');
  const toggle = row.getByRole('switch', { name: /Allow .* in E2E group/ });
  await expect(toggle).not.toBeChecked();
  await page.screenshot({ path: testInfo.outputPath('telegram-groups-off.png'), fullPage: true });

  const saved = page.waitForResponse(
    (reply) => /telegram_groups\//.test(reply.url()) && reply.request().method() === 'PATCH'
  );
  await toggle.click();
  await saved;
  await expect(row.getByRole('switch', { name: /Allow .* in E2E group/ })).toBeChecked();
  await expect(row).toContainText('Allowed by');
  await page.screenshot({ path: testInfo.outputPath('telegram-groups-on.png'), fullPage: true });

  await row.getByRole('link', { name: 'E2E group' }).click();
  await expect(page.getByTestId('telegram-group-state')).toContainText('answers here when mentioned or replied to');
  await expect(page.getByText("This is not the group's history.", { exact: false })).toBeVisible();
});
