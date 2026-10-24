import { expect, test } from '@playwright/test';

test('persisted provider updates preserve credential and active ceremony drafts', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `provider-live-${Date.now()}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  const agent = setup.agents[0];
  const mutate = async (operation) => {
    expect(
      (
        await request.post('/test/e2e/provider_presentation_fixture', {
          data: { account_id: setup.account_id, agent_id: agent.id, operation },
        })
      ).ok()
    ).toBe(true);
  };
  // These are browser-only synthetic responses, never runtime/provider calls.
  let statusReads = 0;
  let runtimeReads = 0;
  await page.route('**/provider_subscription**', async (route) => {
    const req = route.request();
    const url = new URL(req.url());
    if (req.method() === 'GET') runtimeReads++;
    let body;
    if (url.searchParams.has('capabilities')) {
      body = { providers: { anthropic: { oauth_account: true } } };
    } else if (url.pathname.endsWith('/provider_subscription_usage')) {
      body = { windows: [] };
    } else {
      if (req.method() === 'GET') statusReads++;
      body = {
        status: 'awaiting_code',
        verification_url: 'https://example.invalid/sign-in',
        expires_at: new Date(Date.now() + 600_000).toISOString(),
      };
    }
    await route.fulfill({ json: body });
  });
  let drop = false;
  let cable;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (socket) => {
    const server = socket.connectToServer();
    cable = socket;
    server.onMessage((raw) => {
      const message = JSON.parse(raw);
      const model = message.identifier && JSON.parse(message.identifier).model;
      if (message.type === 'confirm_subscription' && model === 'ProviderPresentation') confirmed = true;
      if (!(drop && model === 'ProviderPresentation' && message.message)) socket.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('subscription_agents') || props.includes('provider_subscription')) reloads.push(props);
  });
  try {
    await mutate('prepare');
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    await page.goto(`/accounts/${setup.account_param}/agent_api_keys`);
    await expect.poll(() => confirmed).toBe(true);
    await expect.poll(() => reloads.length).toBeGreaterThan(0);
    await page.waitForLoadState('networkidle');
    // Initial layout catch-up legitimately combines several independent lanes.
    await page.waitForTimeout(700);
    await page.waitForLoadState('networkidle');
    const initialRuntimeReads = runtimeReads;
    const key = page.getByLabel('Anthropic API key', { exact: true });
    await key.fill('unfinished-synthetic-key');
    await mutate('connect');
    await expect(page.getByText('Connected as remote@example.invalid · Synthetic', { exact: true })).toBeVisible();
    await expect(key).toHaveValue('unfinished-synthetic-key');
    // Existing Account hints also refresh the navbar's current-account projection.
    expect([...reloads.at(-1)].sort()).toEqual(
      [
        'subscription_agents',
        'can_manage_ai_credentials',
        'accounts',
        'expired_subscriptions',
        'account',
        'is_account_admin',
      ].sort()
    );
    await page.waitForLoadState('networkidle');
    expect(runtimeReads).toBe(initialRuntimeReads);
    const beforeQuiet = reloads.length;
    await mutate('bookkeeping');
    await page.waitForTimeout(900);
    expect(reloads).toHaveLength(beforeQuiet);
    expect(statusReads).toBe(0);
    drop = true;
    await mutate('late');
    await expect(page.getByText('Connected as remote@example.invalid · Synthetic', { exact: true })).toBeVisible();
    drop = false;
    cable.close({ code: 1012, reason: 'synthetic reconnect' });
    await expect(page.getByText('Connected as late@example.invalid · Synthetic', { exact: true })).toBeVisible({
      timeout: 20_000,
    });
    await expect(key).toHaveValue('unfinished-synthetic-key');
    expect(runtimeReads).toBe(initialRuntimeReads);
    await mutate('clear');
    await page.getByRole('button', { name: 'Connect Claude subscription', exact: true }).click();
    const code = page.getByPlaceholder('Paste the localhost callback URL or code');
    await code.fill('unfinished-browser-code');
    await mutate('connect');
    await expect(code).toHaveValue('unfinished-browser-code');
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(page.getByText('Connected as remote@example.invalid · Synthetic', { exact: true })).toBeVisible();
    await expect(key).toHaveValue('unfinished-synthetic-key');
    await page.screenshot({ path: testInfo.outputPath('provider-live-drafts.png'), fullPage: true });
  } finally {
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
