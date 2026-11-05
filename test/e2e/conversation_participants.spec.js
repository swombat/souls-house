import { expect, test } from '@playwright/test';

for (const mobile of [false, true]) {
  test(`remove conversation residents, keeping history (${mobile ? 'mobile' : 'desktop'})`, async ({
    page,
    request,
  }, testInfo) => {
    if (mobile) await page.setViewportSize({ width: 390, height: 844 });
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `participants-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    const setup = await response.json();
    try {
      const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: 'Keep our history', resident_count: 2 },
      });
      expect(fixtureResponse.ok()).toBe(true);
      const fixture = await fixtureResponse.json();
      const reply = await request.post('/test/e2e/assistant_message', {
        data: { chat_id: fixture.chat_id, content: 'A resident message that must remain' },
      });
      expect(reply.ok()).toBe(true);

      // Confirmed collaborators, not just the account owner, can edit seats.
      await page.goto('/login');
      await page.getByLabel(/email/i).fill(setup.secondary_user.email);
      await page.getByLabel(/password/i).fill(setup.password);
      await page.getByRole('button', { name: /sign in|log in/i }).click();
      await expect(page).not.toHaveURL(/\/login/);
      const path = `/accounts/${setup.account_id}/chats/${fixture.chat_id}`;
      await page.goto(path);
      const residents = page.getByRole('button', { name: 'Conversation residents' });
      await residents.click();
      const removeFirst = page.getByRole('menuitem', { name: /^Remove / }).first();
      const firstName = (await removeFirst.innerText()).replace(/^Remove /, '').trim();
      await page.screenshot({ path: testInfo.outputPath('conversation-residents.png') });

      // Cancelling is genuinely inert.
      page.once('dialog', (dialog) => dialog.dismiss());
      await removeFirst.click();
      await residents.click();
      await expect(page.getByRole('menuitem', { name: `Remove ${firstName}`, exact: true })).toBeVisible();

      page.once('dialog', (dialog) => {
        expect(dialog.message()).toContain('Past messages stay.');
        return dialog.accept();
      });
      await page.getByRole('menuitem', { name: `Remove ${firstName}`, exact: true }).click();
      await expect(
        page.getByText(`[System Notice] ${firstName} has left the conversation.`, { exact: true })
      ).toBeVisible();
      await expect(page.getByText('A resident message that must remain', { exact: true })).toBeVisible();
      await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();

      await page.reload();
      await residents.click();
      await expect(page.getByRole('menuitem', { name: `Remove ${firstName}`, exact: true })).toHaveCount(0);
      const removeLast = page.getByRole('menuitem', { name: /^Remove / });
      await expect(removeLast).toHaveCount(1);
      const lastName = (await removeLast.innerText()).replace(/^Remove /, '').trim();
      page.once('dialog', (dialog) => dialog.accept());
      await removeLast.click();
      await expect(
        page.getByText(`[System Notice] ${lastName} has left the conversation.`, { exact: true })
      ).toBeVisible();
      await expect(residents).toHaveCount(0);
      await expect(page.getByText('A resident message that must remain', { exact: true })).toBeVisible();
      await page.reload();
      await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();
      await expect(residents).toHaveCount(0);

      // The conversation remains editable: a resident can be added again.
      await page.getByRole('button', { name: 'Conversation actions' }).click();
      await expect(page.getByRole('menuitem', { name: 'Add Resident', exact: true })).toBeVisible();
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
}

test('a responding resident gets a clear refusal, not cancellation', async ({ page, request }) => {
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: `participants-busy-${Date.now()}` },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  try {
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, resident_count: 1 },
      })
    ).json();
    const activity = await request.post('/test/e2e/runtime_activity', { data: { chat_id: fixture.chat_id } });
    expect(activity.ok()).toBe(true);
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    const residents = page.getByRole('button', { name: 'Conversation residents' });
    await residents.click();
    const remove = page.getByRole('menuitem', { name: /^Remove / });
    const name = (await remove.innerText()).replace(/^Remove /, '').trim();
    page.once('dialog', (dialog) => dialog.accept());
    await remove.click();
    await expect(
      page.getByText(`${name} is already responding; try again when they are idle`, { exact: true })
    ).toBeVisible();
    await residents.click();
    await expect(page.getByRole('menuitem', { name: `Remove ${name}`, exact: true })).toBeVisible();
    await expect(page.getByText(`[System Notice] ${name} has left the conversation.`, { exact: true })).toHaveCount(0);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
