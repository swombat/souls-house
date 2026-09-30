import { expect, test } from '@playwright/test';

test('renaming preserves sidebar order while a new message moves the thread up', async ({ page, request }) => {
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `recency-${Date.now()}-${Math.random().toString(36).slice(2)}` },
  });
  const setup = await response.json();
  try {
    const createChat = async (secondsAgo) => {
      const fixture = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, seconds_ago: secondsAgo },
      });
      return (await fixture.json()).chat_id;
    };
    const older = await createChat(3600);
    const newer = await createChat(60);
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/chats/${older}`);

    const links = page.locator(
      `a[href$="/accounts/${setup.account_param}/chats/${older}"], a[href$="/accounts/${setup.account_param}/chats/${newer}"]`
    );
    const order = () => links.evaluateAll((items) => items.map((item) => item.getAttribute('href').split('/').pop()));
    await expect.poll(order).toEqual([newer, older]);
    await page.getByTitle('Edit chat title', { exact: true }).click();
    const title = page.locator('main input[type="text"]').filter({ visible: true });
    await title.fill('Renamed without bumping');
    await title.press('Enter');
    await expect(links.nth(1)).toContainText('Renamed without bumping');
    await expect.poll(order).toEqual([newer, older]);
    await page.reload();
    await expect.poll(order).toEqual([newer, older]);

    const composer = page.getByTestId('message-composer');
    await expect(composer.getByRole('status')).toHaveText('Saved');
    await composer.locator('textarea').fill('A new message should bump this conversation');
    await composer.getByRole('button', { name: 'Send message', exact: true }).click();
    await expect.poll(order).toEqual([older, newer]);
    await page.reload();
    await expect.poll(order).toEqual([older, newer]);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
