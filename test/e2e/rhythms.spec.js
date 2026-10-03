import { expect, test } from '@playwright/test';

test('a member sets up a rhythm, starts one by hand, and pauses it', async ({ page, request }, testInfo) => {
  const runId = `rhythms-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const shot = (name) => page.screenshot({ path: testInfo.outputPath(`${name}.png`), fullPage: true });

  try {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);

    const base = `/accounts/${setup.account_param}`;
    await page.goto(`${base}/chats`);
    await page.getByRole('link', { name: 'Rhythms', exact: true }).first().click();
    await expect(page).toHaveURL(new RegExp(`${base}/rhythms$`));
    await expect(page.getByRole('heading', { name: 'What would you like to come back to?' })).toBeVisible();
    await shot('1-empty');

    await page.getByRole('button', { name: 'Start a rhythm' }).click();
    await expect(page.getByRole('heading', { name: 'New rhythm' })).toBeVisible();
    await page.getByLabel('Conversation title', { exact: true }).fill('Weekly reflection');
    await page
      .getByLabel('Opening message', { exact: true })
      .fill(
        "Let's look back over this week's conversations together. What did you notice about me, and how did it land with you? If nothing stands out, say so."
      );
    await page.getByRole('button', { name: 'E2E Researcher' }).click();
    await page.getByRole('button', { name: 'E2E Critic' }).click();
    await page.getByLabel('On', { exact: true }).selectOption('5');
    await page.getByLabel('At', { exact: true }).fill('18:00');
    await page.getByLabel('Timezone', { exact: true }).selectOption('Madrid');
    await expect(page.getByText(/Next one will be called Weekly reflection — /)).toBeVisible();
    await expect(page.getByText(/First one:/)).toContainText('18:00');
    await shot('2-form');

    await page.getByLabel('How often', { exact: true }).selectOption('monthly');
    await page.getByLabel('Day', { exact: true }).selectOption('31');
    await expect(page.getByText(/last day of the month/)).toBeVisible();
    await shot('2b-form-monthly');
    await page.getByLabel('How often', { exact: true }).selectOption('weekly');
    await page.getByLabel('On', { exact: true }).selectOption('5');

    await page.getByRole('button', { name: 'Create rhythm' }).click();
    await expect(page.getByRole('heading', { name: 'Weekly reflection' })).toBeVisible();
    await expect(page.getByText('Every Friday at 18:00')).toBeVisible();
    await expect(page.getByText(/set up by e2e-rhythms-/)).toBeVisible();
    await shot('3-detail');

    await page.getByRole('button', { name: /Start one now/ }).click();
    const occurrence = page.getByRole('link', { name: /Weekly reflection — / });
    await expect(occurrence).toBeVisible();
    await expect(page.getByText('started by hand')).toBeVisible();
    await shot('4-started');

    await occurrence.click();
    await expect(
      page
        .getByText(/by .* · /)
        .or(page.getByText(/Rhythm: Weekly reflection/))
        .first()
    ).toBeVisible();
    await expect(page.getByText(/^Started by e2e-rhythms-/)).toBeVisible();
    await shot('5-conversation');

    await page.goBack();
    await page.getByRole('button', { name: 'Pause', exact: true }).click();
    await page.getByPlaceholder('Reason (optional)').fill('Away for two weeks');
    await page.getByRole('button', { name: 'Pause', exact: true }).click();
    await expect(page.getByText('Away for two weeks')).toBeVisible();
    await expect(page.getByRole('button', { name: /Start one now/ })).toBeDisabled();
    await expect(page.getByText('System', { exact: true })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Pause', exact: true })).toHaveCount(0);
    await shot('6-paused');

    await page.getByRole('link', { name: 'Rhythms', exact: true }).first().click();
    await expect(page.getByText(/Paused by/)).toBeVisible();
    await shot('7-list');
    await page.setViewportSize({ width: 390, height: 844 });
    expect(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth)).toBe(true);
    await shot('8-list-mobile');
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
