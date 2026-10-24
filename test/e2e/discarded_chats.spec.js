import { expect, test } from '@playwright/test';

test('a deleted conversation is hidden and can be restored from the deleted list', async ({ page, request }) => {
  const runId = `discard-parent-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();

  try {
    const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 1, prefix: 'Retained, not deleted' },
    });
    expect(fixtureResponse.ok()).toBe(true);
    const fixture = await fixtureResponse.json();
    const chatPath = `/accounts/${setup.account_id}/chats/${fixture.chat_id}`;
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(chatPath);
    await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();

    page.once('dialog', (dialog) => dialog.accept());
    await page.getByRole('button', { name: 'Conversation actions' }).click();
    await page.getByRole('menuitem', { name: 'Delete', exact: true }).click();
    await expect(page).toHaveURL(/\/accounts\/[^/]+\/chats$/);
    const indexUrl = page.url();
    const directRead = await page.request.get(chatPath);
    expect(directRead.status()).toBe(404);
    expect(await directRead.text()).not.toContain(fixture.first_message);

    await page.goto(`${indexUrl}?show_deleted=true`);
    await expect(page.getByRole('link', { name: 'E2E long conversation', exact: true })).toHaveCount(0);
    await page.getByRole('button', { name: 'Restore E2E long conversation', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Restore E2E long conversation', exact: true })).toHaveCount(0);
    await page.getByRole('link', { name: /E2E long conversation/ }).click();
    await expect(page).toHaveURL(new RegExp(`/chats/${fixture.chat_id}$`));
    await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
  }
});
