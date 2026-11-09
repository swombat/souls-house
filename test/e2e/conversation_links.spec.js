import { expect, test } from '@playwright/test';

async function login(page, user, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(user.email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

test('a conversation ID in a message becomes a link titled with that conversation', async ({ page, request }) => {
  const runId = `conv-links-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  try {
    // Public IDs are hashids; about one in eight has no uppercase letter after
    // the first (or no lowercase), which the extension deliberately skips.
    // Make conversations until one has the recognisable shape.
    const recognisable = (id) => /^[A-Za-z]{6}$/.test(id) && /[A-Z]/.test(id.slice(1)) && /[a-z]/.test(id);
    let target;
    for (let attempt = 0; attempt < 8 && !recognisable(target?.chat_id ?? ''); attempt++) {
      target = await (
        await request.post('/test/e2e/conversation_fixture', {
          data: { account_id: setup.account_id, count: 0, title: 'The linked conversation' },
        })
      ).json();
    }
    expect(recognisable(target.chat_id)).toBe(true);
    const source = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: `Built in ${target.chat_id}, not in xyzABC.` },
      })
    ).json();

    await login(page, setup.secondary_user, setup.password);
    await page.goto(`/accounts/${setup.account_id}/chats/${source.chat_id}`);

    const link = page.locator(`a[data-conversation-ref="${target.chat_id}"]`);
    await expect(link).toHaveText('The linked conversation');
    await expect(link).toHaveAttribute('href', new RegExp(`^/accounts/[A-Za-z0-9]+/chats/${target.chat_id}$`));
    // An ID that names no conversation of this account reads as written.
    await expect(page.getByText('not in xyzABC.', { exact: false })).toBeVisible();
    await expect(page.locator('a[data-conversation-ref="xyzABC"]')).toHaveCount(0);

    await link.click();
    await expect(page).toHaveURL(new RegExp(`/chats/${target.chat_id}$`));
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
