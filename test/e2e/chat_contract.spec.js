import { expect, test } from '@playwright/test';

async function login(page, user, password) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(user.email);
  await page.getByLabel(/password/i).fill(password);
  await page.getByRole('button', { name: /sign in|log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

async function setupRun(request) {
  const runId = `${Date.now()}-${Math.random().toString(36).slice(2)}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  return response.json();
}

async function cleanupRun(request, runId) {
  await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
}

async function getRunState(request, runId) {
  const response = await request.post('/test/e2e/state', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  return response.json();
}

async function startGroupChat(page, accountId, firstMessage) {
  await page.goto(`/accounts/${accountId}/chats`);
  await expect(page.getByRole('heading', { name: 'New Chat' })).toBeVisible();

  const chatForm = page.locator('main');
  await expect(chatForm.getByRole('button', { name: /E2E Researcher/i })).toBeVisible();
  await expect(chatForm.getByRole('button', { name: /E2E Critic/i })).toBeVisible();
  await expect(chatForm.getByRole('button', { name: /E2E Paused Fork/i })).toBeVisible();
  await expect(chatForm.getByRole('button', { name: /E2E Inactive Fork/i })).toBeHidden();
  await expect(chatForm.getByRole('button', { name: /^Model$/i })).toBeHidden();
  await expect(page.getByLabel(/allow web access/i)).toBeHidden();

  const composer = page.locator('main textarea').last();
  await composer.fill(firstMessage);
  await page.locator('main button').last().click();

  await expect(page).toHaveURL(/\/accounts\/[^/]+\/chats\/[^/]+$/);
  await expect(page.getByText(firstMessage)).toBeVisible();

  return page.url().split('/').pop();
}

test.describe('browser contracts', () => {
  let setup;

  test.beforeEach(async ({ request }) => {
    setup = await setupRun(request);
  });

  test.afterEach(async ({ request }) => {
    await cleanupRun(request, setup.run_id);
  });

  test('user can log in, create a multi-agent chat, and see deterministic thinking output', async ({
    page,
    request,
  }) => {
    await login(page, setup.primary_user, setup.password);
    const chatId = await startGroupChat(page, setup.account_id, 'Please compare the two test agents.');

    const stateResponse = await request.post('/test/e2e/state', {
      data: { run_id: setup.run_id, account_id: setup.account_id },
    });
    expect(stateResponse.ok()).toBe(true);
    const state = await stateResponse.json();
    expect(state.account.chats).toContainEqual(
      expect.objectContaining({
        id: chatId,
        manual_responses: true,
        web_access: false,
        agent_names: expect.arrayContaining(['E2E Researcher', 'E2E Critic']),
      })
    );
    expect(state.account.chats.find((chat) => chat.id === chatId).agent_names).not.toContain('E2E Paused Fork');

    const response = await request.post('/test/e2e/assistant_message', {
      data: {
        chat_id: chatId,
        thinking: 'I will compare both deterministic test agents before answering.',
        content: 'The researcher gathers context; the critic checks assumptions.',
      },
    });
    expect(response.ok()).toBe(true);

    await page.reload();
    await expect(page.getByText('The researcher gathers context; the critic checks assumptions.')).toBeVisible();
    await expect(page.getByText(/I will compare both deterministic test agents/)).toBeVisible();
  });

  test('agent image attachments render as thumbnails and open the lightbox', async ({ page, request }) => {
    await login(page, setup.primary_user, setup.password);
    const chatId = await startGroupChat(page, setup.account_id, 'Please make a small test image.');

    const response = await request.post('/test/e2e/assistant_message', {
      data: {
        chat_id: chatId,
        content: 'Here is the generated image.',
        attach_image: true,
      },
    });
    expect(response.ok()).toBe(true);

    await page.reload();
    await expect(page.getByText('Here is the generated image.')).toBeVisible();
    const thumbnail = page.getByRole('img', { name: 'agent-generated-image.png' }).first();
    await expect(thumbnail).toBeVisible();
    await thumbnail.click();

    await expect(page.getByText('View full size original')).toBeVisible();
    await expect(page.getByTitle('Download original')).toHaveAttribute('href', /rails\/active_storage/);
    await expect(page.getByRole('img', { name: 'agent-generated-image.png' }).last()).toBeVisible();
  });

  test('hosted agent promotion page explains local sandbox testing', async ({ page }) => {
    await login(page, setup.primary_user, setup.password);
    const agentId = setup.agents[0].id;

    await page.goto(`/accounts/${setup.account_id}/agents/${agentId}/promote`);

    await expect(page.getByRole('heading', { name: /Promote E2E Researcher/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /Promote to sandbox/ })).toBeVisible();
    await expect(page.getByText(/without a GitHub repo, master key, DNS, or SSH deploy step/)).toBeVisible();
    await expect(page.getByText(/published to/)).toBeVisible();
    await expect(page.getByText(/127.0.0.1/)).toBeVisible();
  });

  test('agent navigation is direct and whiteboards only appear for configured accounts', async ({ page }) => {
    await login(page, setup.primary_user, setup.password);

    await page.goto(`/accounts/${setup.empty_account_id}/chats`);
    const accountMenu = page.getByRole('button', { name: 'User account menu' });
    await accountMenu.click();
    await expect(page.getByRole('menuitem', { name: 'Whiteboards' })).toBeHidden();
    await page.keyboard.press('Escape');

    await accountMenu.click();
    await page.locator('[data-dropdown-menu-sub-trigger]').filter({ hasText: 'Account' }).hover();
    await page.getByRole('menuitem', { name: `E2E ${setup.run_id} Team`, exact: true }).click();
    await expect(page).toHaveURL(/\/accounts\/[^/]+\/chats$/);
    const switchedAccountId = new URL(page.url()).pathname.split('/')[2];

    await expect(page.locator('nav').getByRole('link', { name: 'Documentation', exact: true })).toBeHidden();
    await expect(page.locator('nav').getByRole('link', { name: 'About', exact: true })).toBeHidden();
    const agentsLink = page.locator('nav').getByRole('link', { name: 'Residents', exact: true });
    await expect(agentsLink).toHaveAttribute('href', new RegExp(`/accounts/${switchedAccountId}/agents$`));
    await agentsLink.click();
    await expect(page).toHaveURL(`/accounts/${switchedAccountId}/agents`);
    await expect(page.getByRole('heading', { name: 'Residents' })).toBeVisible();

    await accountMenu.click();
    const whiteboardsItem = page.getByRole('menuitem', { name: 'Whiteboards' });
    await expect(whiteboardsItem).toBeVisible();
    await whiteboardsItem.click();
    await expect(page).toHaveURL(/\/accounts\/[^/]+\/whiteboards$/);
    await expect(page.getByRole('heading', { name: 'Whiteboards' })).toBeVisible();
  });

  test('user can promote a hosted agent into a local Docker sandbox', async ({ page, request }) => {
    await login(page, setup.primary_user, setup.password);
    const agentId = setup.agents[0].id;

    await page.goto(`/accounts/${setup.account_id}/agents/${agentId}/promote`);
    await expect(page.getByRole('heading', { name: /Promote E2E Researcher/ })).toBeVisible();
    await expect(page.getByText(/Docker daemon:/)).toBeVisible();
    await expect(page.getByText(/Runtime image present:/)).toBeVisible();

    await page.getByRole('button', { name: /Promote to sandbox/ }).click();
    await expect(page.getByText(/Current runtime:\s*migrating/)).toBeVisible();

    const promoteResponse = await request.post('/test/e2e/perform_promote', {
      data: { agent_id: agentId },
    });
    expect(promoteResponse.ok()).toBe(true);

    await page.reload();
    await expect(page.getByText(/Current runtime:\s*external/)).toBeVisible({ timeout: 60_000 });
    await expect(page.getByText(/Health:\s*healthy/)).toBeVisible();
    await expect(page.getByText(/Container exists:\s*yes/)).toBeVisible();
  });

  test('chat messages sync between two logged-in browser windows', async ({ browser, page }) => {
    await login(page, setup.primary_user, setup.password);
    await startGroupChat(page, setup.account_id, 'Initial message from the primary user.');
    const chatUrl = page.url();

    const secondContext = await browser.newContext();
    const secondPage = await secondContext.newPage();
    await login(secondPage, setup.secondary_user, setup.password);
    await secondPage.goto(chatUrl);
    await expect(secondPage.getByText('Initial message from the primary user.')).toBeVisible();

    await secondPage.locator('main textarea').last().fill('Synced message from another browser.');
    await secondPage.locator('main button').last().click();

    await expect(page.getByText('Synced message from another browser.')).toBeVisible();
    await secondContext.close();
  });

  test('new conversations remain agent-only without an account conversation-mode setting', async ({ page }) => {
    await login(page, setup.primary_user, setup.password);
    await page.goto(`/accounts/${setup.account_id}/edit`);
    await expect(page.getByRole('heading', { name: 'Edit Account' })).toBeVisible();
    await expect(page.getByText('New Conversation Default')).toBeHidden();

    await page.goto(`/accounts/${setup.account_id}/chats`);
    const chatForm = page.locator('main');
    await expect(chatForm.getByRole('button', { name: /^Model$/i })).toBeHidden();
    await expect(page.getByLabel(/allow web access/i)).toBeHidden();
    await expect(chatForm.getByRole('button', { name: /E2E Researcher/i })).toBeVisible();
    await expect(chatForm.getByRole('button', { name: /E2E Critic/i })).toBeVisible();
    await expect(chatForm.getByRole('button', { name: /E2E Paused Fork/i })).toBeVisible();
    await expect(chatForm.getByRole('button', { name: /E2E Inactive Fork/i })).toBeHidden();

    const agentButtonLabels = await chatForm.getByRole('button').filter({ hasText: /E2E/ }).allTextContents();
    expect(agentButtonLabels.findIndex((label) => label.includes('E2E Paused Fork'))).toBeGreaterThan(
      agentButtonLabels.findIndex((label) => label.includes('E2E Critic'))
    );
  });

  test('user can update profile details, timezone, and avatar', async ({ page, request }) => {
    await login(page, setup.primary_user, setup.password);
    await page.goto('/user/edit');
    await expect(page.getByRole('heading', { name: 'User Settings' })).toBeVisible();

    await page.getByLabel('First Name').fill('E2E Profile');
    await page.getByLabel('Last Name').fill('Tester');
    await page.getByText('Select your timezone').click();
    await page.getByRole('option', { name: /London/ }).click();
    await page.getByRole('button', { name: 'Save Changes' }).click();

    await expect(page.getByText(/Settings updated successfully/)).toBeVisible();

    await page.getByRole('button', { name: /update profile picture/i }).click();
    await page.locator('#avatar-upload').setInputFiles('test/fixtures/files/test_avatar.png');
    await expect(page.getByRole('dialog')).not.toBeVisible();

    const stateResponse = await request.post('/test/e2e/state', {
      data: { run_id: setup.run_id, account_id: setup.account_id },
    });
    expect(stateResponse.ok()).toBe(true);
    const state = await stateResponse.json();
    expect(state.primary_user.full_name).toBe('E2E Profile Tester');
    expect(state.primary_user.timezone).toBe('London');
    expect(state.primary_user.avatar_attached).toBe(true);
  });

  test('owner can invite a user who accepts and joins the account', async ({ browser, page, request }) => {
    const invitedEmail = `e2e-${setup.run_id}-invitee@example.com`;

    await login(page, setup.primary_user, setup.password);
    await page.goto(`/accounts/${setup.account_id}`);
    await expect(page.getByRole('heading', { name: 'Account Settings' })).toBeVisible();

    await page.getByRole('button', { name: 'Invite Member' }).click();
    await page.getByLabel('Email Address').fill(invitedEmail);
    await page.getByRole('button', { name: 'Send Invitation' }).click();
    await expect(page.getByRole('cell', { name: invitedEmail })).toBeVisible();

    const invitationResponse = await request.post('/test/e2e/invitation_url', { data: { email: invitedEmail } });
    expect(invitationResponse.ok()).toBe(true);
    const { url } = await invitationResponse.json();

    const invitedContext = await browser.newContext();
    const invitedPage = await invitedContext.newPage();
    await invitedPage.goto(url);
    await expect(invitedPage.getByRole('heading', { name: 'Email Confirmed!' })).toBeVisible();
    await invitedPage.getByLabel('First Name').fill('Invited');
    await invitedPage.getByLabel('Last Name').fill('Member');
    await invitedPage.getByLabel('Password', { exact: true }).fill(setup.password);
    await invitedPage.getByLabel('Confirm Password').fill(setup.password);
    await invitedPage.getByRole('button', { name: 'Complete Setup' }).click();
    await expect(invitedPage).toHaveURL(/\/$/);
    await invitedContext.close();

    const state = await getRunState(request, setup.run_id);
    expect(state.account.members).toContainEqual(
      expect.objectContaining({
        email: invitedEmail,
        role: 'member',
        confirmed: true,
      })
    );
  });

  test('agent settings can be edited and saved', async ({ page, request }) => {
    await login(page, setup.primary_user, setup.password);
    await page.goto(setup.agents[0].edit_url);
    await expect(page.getByRole('heading', { name: 'Edit Resident' })).toBeVisible();

    await page.getByLabel('Display name').fill('E2E Refactor Sentinel');
    await page.getByRole('button', { name: 'Integrations' }).click();
    await expect(page.getByRole('heading', { name: 'Integrations' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Telegram' })).toBeVisible();
    await page.getByRole('button', { name: 'Set up' }).click();
    await expect(page.getByRole('heading', { name: 'Create a Telegram bot' })).toBeVisible();
    await expect(page.getByRole('link', { name: '@BotFather in Telegram' })).toHaveAttribute(
      'href',
      'https://t.me/botfather'
    );
    await expect(page.getByText('/newbot')).toBeVisible();
    await page.getByRole('button', { name: 'All integrations' }).click();
    await expect(page.getByRole('button', { name: 'Set up' })).toBeVisible();

    await page.getByRole('button', { name: 'Settings' }).click();
    await expect(page.getByRole('heading', { name: 'Settings' })).toBeVisible();
    await page.getByLabel('Heartbeat wakes per day').fill('4');
    await page.locator('label[for="paused"]').click();
    await page.getByRole('button', { name: 'Update Resident' }).click();

    await expect(page).toHaveURL(/\/accounts\/[^/]+\/agents$/);
    await expect(page.getByText(/Resident updated/).first()).toBeVisible();

    const state = await getRunState(request, setup.run_id);
    expect(state.agents).toContainEqual(
      expect.objectContaining({
        name: 'E2E Refactor Sentinel',
        paused: true,
        heartbeat_wakes_per_day: 4,
      })
    );
  });

  test('account AI API keys can be configured without exposing saved values', async ({ page }) => {
    await login(page, setup.primary_user, setup.password);
    await page.goto(`/accounts/${setup.account_id}/agent_api_keys`);

    const openRouterKey = page.getByLabel('OpenRouter API key', { exact: true });
    await expect(openRouterKey).toHaveAttribute('type', 'password');
    await openRouterKey.fill('e2e-openrouter-secret');
    await expect(page.getByText('Shared AI keys are available as a fallback')).toBeHidden();

    await Promise.all([
      page.waitForResponse(
        (response) => response.url().endsWith('/agent_api_keys') && response.request().method() === 'PUT'
      ),
      page.getByRole('button', { name: 'Save Resident API Keys' }).click(),
    ]);
    await expect(page.getByText('Set', { exact: true })).toBeVisible();
    await expect(page).toHaveURL(/\/accounts\/[^/]+\/agent_api_keys$/);

    await page.goto(`/accounts/${setup.account_id}/agent_api_keys`);
    await expect(page.getByText('Set', { exact: true })).toBeVisible();
    await expect(page.getByText('Not set', { exact: true })).toHaveCount(7);
    await expect(page.getByLabel('OpenRouter API key', { exact: true })).toHaveValue('');
    await expect(page.getByLabel('OpenRouter API key', { exact: true })).toHaveAttribute(
      'placeholder',
      'Enter a replacement key'
    );
    await expect(page.locator('body')).not.toContainText('e2e-openrouter-secret');
  });
});

test.describe('admin account management', () => {
  let setup;

  test.beforeEach(async ({ request }) => {
    setup = await setupRun(request);
  });

  test.afterEach(async ({ request }) => {
    await cleanupRun(request, setup.run_id);
  });

  test('site admin can add and remove members, convert account type, and disable an account', async ({
    page,
    request,
  }) => {
    page.on('dialog', (dialog) => dialog.accept());

    await login(page, setup.admin_user, setup.password);
    await page.goto(`/admin/accounts?account_id=${setup.account_id}`);
    const details = page.locator('main');
    await expect(details.getByRole('heading', { name: `E2E ${setup.run_id} Team` })).toBeVisible();

    const sharedAiCredentials = details.getByRole('switch', { name: 'Use shared keys as fallback' });
    await expect(sharedAiCredentials).toHaveAttribute('aria-checked', 'false');
    await sharedAiCredentials.click();
    await expect(sharedAiCredentials).toHaveAttribute('aria-checked', 'true');

    const secondaryRow = details.getByRole('row').filter({ hasText: setup.secondary_user.email });
    await expect(secondaryRow).toBeVisible();
    await secondaryRow.getByRole('button', { name: /remove/i }).click();
    await expect(secondaryRow).toBeHidden();

    await details.getByRole('button', { name: 'Convert to Personal' }).click();
    await expect(details.getByRole('button', { name: 'Convert to Team' })).toBeVisible();

    await details.getByRole('button', { name: 'Convert to Team' }).click();
    await expect(details.getByRole('button', { name: 'Convert to Personal' })).toBeVisible();

    await details.getByLabel('Existing user email').fill(setup.secondary_user.email);
    await details.getByRole('button', { name: 'Add User' }).click();
    const readdedSecondaryRow = details.getByRole('row').filter({ hasText: setup.secondary_user.email });
    await expect(readdedSecondaryRow).toBeVisible();

    await details.getByRole('button', { name: 'Disable Account' }).click();
    await expect(details.getByRole('button', { name: 'Enable Account' })).toBeVisible();

    const stateResponse = await request.post('/test/e2e/state', {
      data: { run_id: setup.run_id, account_id: setup.account_id },
    });
    expect(stateResponse.ok()).toBe(true);
    const state = await stateResponse.json();
    expect(state.account.members).toHaveLength(2);
    expect(state.account.members).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ email: setup.primary_user.email, role: 'owner', confirmed: true }),
        expect.objectContaining({ email: setup.secondary_user.email, role: 'member', confirmed: true }),
      ])
    );
    expect(state.account.account_type).toBe('team');
    expect(state.account.disabled).toBe(true);
    expect(state.account.active).toBe(false);
    expect(state.account.use_system_ai_credentials).toBe(true);
  });
});
