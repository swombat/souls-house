import { expect, test } from '@playwright/test';

async function signIn(page, email, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

async function openManage(page) {
  await page.getByRole('button', { name: 'Conversation actions' }).click();
  await page.getByRole('menuitem', { name: 'Manage residents', exact: true }).click();
  const dialog = page.getByRole('dialog', { name: 'Manage residents' });
  await expect(dialog).toBeVisible();
  return dialog;
}

for (const mobile of [false, true]) {
  test(`manage conversation residents, keeping history (${mobile ? 'mobile' : 'desktop'})`, async ({
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
      await signIn(page, setup.secondary_user.email, setup.password);
      await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);

      // The separate header menu is gone; residents are managed from the ⋯ menu.
      await expect(page.getByRole('button', { name: 'Conversation residents' })).toHaveCount(0);
      let dialog = await openManage(page);
      // Seated residents come first and ticked; the account's others follow unticked.
      const boxes = dialog.getByRole('checkbox');
      await expect(dialog.getByRole('checkbox', { checked: true })).toHaveCount(2);
      await expect(boxes.nth(0)).toBeChecked();
      await expect(boxes.nth(1)).toBeChecked();
      const save = dialog.getByRole('button', { name: 'Save', exact: true });
      await expect(save).toBeDisabled();
      if (mobile) {
        const list = await dialog.getByTestId('manage-residents-list').boundingBox();
        const saveBox = await save.boundingBox();
        expect(list.x).toBeGreaterThanOrEqual(0);
        expect(list.x + list.width).toBeLessThanOrEqual(390);
        expect(saveBox.y + saveBox.height).toBeLessThanOrEqual(844);
      }
      await page.screenshot({ path: testInfo.outputPath('manage-residents.png') });

      const firstLabel = dialog.locator('label').nth(0);
      const firstName = (await firstLabel.locator('span').first().innerText()).trim();

      // Cancelling is genuinely inert.
      await boxes.nth(0).uncheck();
      await dialog.getByRole('button', { name: 'Cancel' }).click();
      dialog = await openManage(page);
      await expect(dialog.getByRole('checkbox', { name: firstName })).toBeChecked();

      await dialog.getByRole('checkbox', { name: firstName }).uncheck();
      await dialog.getByRole('button', { name: 'Save', exact: true }).click();
      await expect(
        page.getByText(`[System Notice] ${firstName} has left the conversation.`, { exact: true })
      ).toBeVisible();
      await expect(page.getByText('A resident message that must remain', { exact: true })).toBeVisible();
      await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();

      // After a reload the removed resident is offered unticked, and can come back.
      await page.reload();
      dialog = await openManage(page);
      await expect(dialog.getByRole('checkbox', { name: firstName })).not.toBeChecked();
      await dialog.getByRole('checkbox', { name: firstName }).check();
      await dialog.getByRole('button', { name: 'Save', exact: true }).click();
      await expect(
        page.getByText(`[System Notice] ${firstName} has joined the conversation.`, { exact: true })
      ).toBeVisible();

      // Unticking everyone leaves an editable conversation with its history.
      dialog = await openManage(page);
      for (const box of await dialog.getByRole('checkbox').all()) if (await box.isChecked()) await box.uncheck();
      await dialog.getByRole('button', { name: 'Save', exact: true }).click();
      await expect(dialog).toBeHidden();
      await page.reload();
      await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();
      dialog = await openManage(page);
      for (const box of await dialog.getByRole('checkbox').all()) await expect(box).not.toBeChecked();
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
    await signIn(page, setup.primary_user.email, setup.password);
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    let dialog = await openManage(page);
    const ticked = dialog.getByRole('checkbox', { checked: true });
    await expect(ticked).toHaveCount(1);
    const name = (
      await dialog
        .locator('label', { has: page.locator('input:checked') })
        .locator('span')
        .first()
        .innerText()
    ).trim();
    await dialog.getByRole('checkbox', { name }).uncheck();
    await dialog.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(
      page.getByText(`${name} is already responding; try again when they are idle`, { exact: true })
    ).toBeVisible();
    dialog = await openManage(page);
    await expect(dialog.getByRole('checkbox', { name })).toBeChecked();
    await expect(page.getByText(`[System Notice] ${name} has left the conversation.`, { exact: true })).toHaveCount(0);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
