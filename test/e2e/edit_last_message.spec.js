import { expect, test } from '@playwright/test';

// Daniel (JRyqxj): on desktop, Up in the empty message box edits the last
// message you posted. This drives the real page: post through the composer,
// let a resident's reply land after it, press Up, and the edit drawer opens on
// your message (not the reply) with the cursor at the end; Save updates the
// bubble and focus comes back to the box.
test.describe('up arrow edits your last message', () => {
  let setup;

  test.beforeEach(async ({ page, request }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `edit-last-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();

    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
  });

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  test('post, a reply lands, Up opens your message at the end, Save updates it', async ({ page, request }) => {
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: 'Older message', resident_count: 1 },
      })
    ).json();
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);

    const box = page.getByTestId('message-composer').getByRole('textbox');
    await box.fill('Typo in thsi one');
    await box.press('Enter');
    await expect(page.getByText('Typo in thsi one')).toBeVisible();
    await expect(box).toHaveValue('');

    await request.post('/test/e2e/assistant_message', {
      data: { chat_id: fixture.chat_id, content: 'A resident reply after it' },
    });
    await expect(page.getByText('A resident reply after it').first()).toBeVisible({ timeout: 10_000 });

    await box.focus();
    await box.press('ArrowUp');
    const editor = page.getByTestId('edit-message-text');
    await expect(editor).toBeVisible();
    await expect(editor).toHaveValue('Typo in thsi one');
    await expect(editor).toBeFocused();
    const caret = await editor.evaluate((el) => [el.selectionStart, el.selectionEnd, el.value.length]);
    expect(caret).toEqual([16, 16, 16]);

    await editor.fill('Typo in this one');
    await page.getByRole('button', { name: 'Save' }).click();
    await expect(editor).toBeHidden();
    await expect(page.getByText('Typo in this one')).toBeVisible();
    await expect(page.getByText('Typo in thsi one')).toHaveCount(0);
    await expect(box).toBeFocused();

    // Up again reaches the same message (an edit does not use up the shortcut).
    await box.press('ArrowUp');
    await expect(editor).toHaveValue('Typo in this one');
    await page.keyboard.press('Escape');
    await expect(editor).toBeHidden();
    await expect(box).toBeFocused();
  });

  test('with a draft in the box, Up moves the cursor and opens nothing', async ({ page, request }) => {
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: 'Earlier message', resident_count: 1 },
      })
    ).json();
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);

    const box = page.getByTestId('message-composer').getByRole('textbox');
    await box.fill('first line');
    await box.press('Shift+Enter');
    await box.pressSequentially('second');
    await box.press('ArrowUp');
    await expect(page.getByTestId('edit-message-text')).toBeHidden();
    const caret = await box.evaluate((el) => el.selectionStart);
    expect(caret).toBeLessThanOrEqual('first line'.length);
  });
});
