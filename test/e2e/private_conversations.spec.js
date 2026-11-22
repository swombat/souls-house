import { expect, test } from '@playwright/test';

// Release walkthrough for private conversations (eKmnrJ, #1089), on a phone-sized screen.
// One synthetic chat, made private after it starts: its creator sees it with a lock; a member and a site admin
// who aren't in it get no row, no search hit and a 404 on its address.

const WORD = 'quartzlantern';
// Positive control: an ordinary chat every member sees, so a blanket denial can't pass.
const OPEN_WORD = 'plainmarble';

async function signIn(page, email, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

test.use({ viewport: { width: 390, height: 844 } });

test('a private conversation is seen only by the people in it', async ({ browser, page, request }) => {
  test.setTimeout(90_000);
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `private-${Date.now()}-${Math.random().toString(36).slice(2)}` },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    await signIn(page, setup.primary_user.email, setup.password);
    // First an ordinary conversation, the control.
    await page.goto(`/accounts/${setup.account_id}/chats`);
    await page.getByTitle('Edit chat title').click();
    await page.locator('header input[type="text"]').fill('Open room');
    await page.locator('header input[type="text"]').press('Enter');
    await page.getByTestId('message-composer').locator('textarea').fill(`A ${OPEN_WORD} for everyone`);
    await page.getByRole('button', { name: 'Start conversation' }).click();
    await expect(page).toHaveURL(/\/chats\/[^/]+$/);
    const openUrl = new URL(page.url()).pathname;

    // The creator starts an ordinary one, then makes it private from the ⋯ menu.
    await page.goto(`/accounts/${setup.account_id}/chats`);
    await page.getByTitle('Edit chat title').click();
    await page.locator('header input[type="text"]').fill('Stone room');
    await page.locator('header input[type="text"]').press('Enter');
    await page.getByTestId('message-composer').locator('textarea').fill(`A ${WORD} for the stone`);
    await page.getByRole('button', { name: 'Start conversation' }).click();
    await expect(page).toHaveURL(/\/chats\/[^/]+$/);
    const chatUrl = new URL(page.url()).pathname;
    page.once('dialog', async (dialog) => {
      expect(dialog.message()).toContain("The house's operators can still see it.");
      await dialog.accept();
    });
    await page.getByRole('button', { name: 'Conversation actions' }).click();
    await page.getByTestId('make-private').click();
    await expect(page.getByTestId('chat-private-lock').first()).toBeAttached();
    await page.getByRole('button', { name: 'Conversation actions' }).click();
    await expect(page.getByTestId('make-private')).toHaveCount(0);
    await page.keyboard.press('Escape');
    await expect(page.getByTitle('Edit chat title')).toHaveText('Stone room');

    // Its creator finds it again in search, and the lock is on its row.
    await page.goto(`/accounts/${setup.account_id}/chats/search?q=${WORD}`);
    await expect(page.getByText('Stone room').first()).toBeVisible();
    await page.goto(chatUrl);
    await expect(page.getByTestId('chat-private-lock').first()).toBeAttached();

    // Nobody else on the account: not a member, not a site admin.
    for (const outsider of [setup.secondary_user, setup.admin_user]) {
      expect(outsider?.email).toBeTruthy();
      const context = await browser.newContext({ viewport: { width: 390, height: 844 } });
      const other = await context.newPage();
      await signIn(other, outsider.email, setup.password);
      await other.goto(`/accounts/${setup.account_id}/chats`);
      await expect(other.getByText('Open room').first()).toBeAttached();
      await expect(other.getByText('Stone room')).toHaveCount(0);
      await expect(other.getByTestId('chat-private-lock')).toHaveCount(0);
      await other.goto(`/accounts/${setup.account_id}/chats/search?q=${OPEN_WORD}`);
      await expect(other.getByText('Open room').first()).toBeVisible();
      await other.goto(`/accounts/${setup.account_id}/chats/search?q=${WORD}`);
      await expect(other.getByText(/No results found/)).toBeVisible();
      await expect(other.getByText('Stone room')).toHaveCount(0);
      await expect(other.getByText('for the stone')).toHaveCount(0);
      const control = await other.goto(openUrl);
      expect(control.status()).toBe(200);
      await expect(other.getByText(`A ${OPEN_WORD} for everyone`)).toBeVisible();
      const direct = await other.goto(chatUrl);
      expect(direct.status()).toBe(404);
      await expect(other.getByText('for the stone')).toHaveCount(0);
      await expect(other.getByText('Stone room')).toHaveCount(0);
      await context.close();
    }
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
