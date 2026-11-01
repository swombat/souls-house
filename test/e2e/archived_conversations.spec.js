import { expect, test } from '@playwright/test';

async function login(page, user, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(user.email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).not.toHaveURL(/\/login/);
}

async function action(page, name) {
  await page.getByRole('button', { name: 'Conversation actions' }).click();
  await page.getByRole('menuitem', { name, exact: true }).click();
}

for (const mobile of [false, true]) {
  test(`archived conversations are opt-in for an ordinary member (${mobile ? 'mobile' : 'desktop'})`, async ({
    page,
    request,
  }, testInfo) => {
    if (mobile) await page.setViewportSize({ width: 390, height: 844 });
    const runId = `archive-${Date.now()}-${Math.random().toString(36).slice(2)}`;
    const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
    expect(setupResponse.ok()).toBe(true);
    const setup = await setupResponse.json();
    try {
      const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: 'Preserved archive transcript' },
      });
      expect(fixtureResponse.ok()).toBe(true);
      const fixture = await fixtureResponse.json();
      const chatPath = `/accounts/${setup.account_id}/chats/${fixture.chat_id}`;
      const sidebar = page.locator('aside');
      const archivedLink = sidebar.getByRole('link', { name: /E2E long conversation/ });
      async function openSidebar() {
        if (mobile) await page.locator('header:has([aria-label="Conversation actions"]) button').first().click();
      }

      await login(page, setup.secondary_user, setup.password);
      await page.goto(chatPath);
      await action(page, 'Archive');
      await expect(page.getByText('This conversation has been archived.', { exact: true })).toBeVisible();
      // Direct access remains usable even though its sidebar item is absent.
      await page.goto(chatPath);
      await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();
      await expect(page.getByText('This conversation has been archived.', { exact: true })).toBeVisible();
      await expect(page.getByTestId('message-composer').locator('textarea')).toBeDisabled();
      await openSidebar();
      await expect(sidebar.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();
      // Existing account policy treats confirmed members as trusted managers.
      // This change must not narrow the older Deleted control's permissions.
      await expect(sidebar.getByRole('checkbox', { name: 'Deleted', exact: true })).not.toBeChecked();
      await expect(archivedLink).toHaveCount(0);
      await sidebar.getByRole('checkbox', { name: 'Archived' }).check();
      await expect(archivedLink).toBeVisible();
      await archivedLink.click();
      await expect(page).toHaveURL(/show_archived=true/);
      if (mobile) {
        await sidebar.getByRole('button', { name: 'Close sidebar', exact: true }).click();
        await openSidebar();
      }
      await expect(sidebar.getByRole('checkbox', { name: 'Archived' })).toBeChecked();
      await expect(archivedLink).toBeVisible();
      await page.screenshot({ path: testInfo.outputPath('show-archived.png') });
      await sidebar.getByRole('checkbox', { name: 'Archived' }).uncheck();
      await expect(archivedLink).toHaveCount(0);
      await expect(page.getByText(fixture.first_message, { exact: true })).toBeVisible();
      if (mobile) await sidebar.getByRole('button', { name: 'Close sidebar', exact: true }).click();
      await action(page, 'Unarchive');
      await page.goto(chatPath);
      await expect(page.getByTestId('message-composer').locator('textarea')).toBeEnabled();
      await openSidebar();
      await expect(archivedLink).toBeVisible();
      await expect(sidebar.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();
    } finally {
      await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
    }
  });
}

test('existing owner deleted audit mode includes archived with either checkbox state', async ({ page, request }) => {
  const runId = `archive-audit-${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  try {
    const fixtureResponse = await request.post('/test/e2e/conversation_fixture', {
      data: { account_id: setup.account_id, count: 1 },
    });
    const fixture = await fixtureResponse.json();
    await login(page, setup.primary_user, setup.password);
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    await action(page, 'Archive');
    await expect(page.getByText('This conversation has been archived.', { exact: true })).toBeVisible();
    const sidebar = page.locator('aside');
    const archivedLink = sidebar.getByRole('link', { name: /E2E long conversation/ });
    await expect(archivedLink).toHaveCount(0);
    await sidebar.getByRole('checkbox', { name: 'Deleted', exact: true }).check();
    await expect(page).toHaveURL(/show_deleted=true/);
    await expect(archivedLink).toBeVisible();
    await sidebar.getByRole('checkbox', { name: 'Archived' }).check();
    await expect(page).toHaveURL(/show_archived=true/);
    await expect(archivedLink).toBeVisible();
    await sidebar.getByRole('checkbox', { name: 'Deleted', exact: true }).uncheck();
    await expect(page).not.toHaveURL(/show_deleted/);
    await expect(archivedLink).toBeVisible();
    await sidebar.getByRole('checkbox', { name: 'Archived' }).uncheck();
    await expect(page).not.toHaveURL(/show_archived/);
    await expect(archivedLink).toHaveCount(0);
  } finally {
    await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  }
});
