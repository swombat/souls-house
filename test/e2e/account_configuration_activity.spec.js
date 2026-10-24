import { expect, test } from '@playwright/test';

test('open account settings reconcile pristine values and retain drafts across live updates and reconnect', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `account-config-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  let socket;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (cable) => {
    socket = cable;
    cable.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.type === 'confirm_subscription' && JSON.parse(message.identifier).model === 'Account')
        confirmed = true;
      if (!drop || !message.message) cable.send(raw);
    });
  });
  const partials = [];
  page.on('request', (req) => {
    const props = req.headers()['x-inertia-partial-data'];
    if (props) partials.push(props.split(','));
  });
  const editor = await page.context().newPage();
  const saveName = async (name) => {
    await editor.getByLabel('Account name', { exact: true }).fill(name);
    await editor.getByRole('button', { name: 'Save name', exact: true }).click();
    await expect(editor.getByRole('button', { name: 'Save name', exact: true })).toBeDisabled();
    await expect(editor.getByTestId('nav-account-name')).toHaveText(name);
  };
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}`;
    await page.goto(base);
    await editor.goto(base);
    await expect.poll(() => confirmed).toBe(true);
    await saveName('Live account name');
    await expect(page.getByLabel('Account name', { exact: true })).toHaveValue('Live account name');
    await expect(page.getByTestId('nav-account-name')).toHaveText('Live account name');

    const cap = page.getByTestId('resident-handoff-cap');
    await editor.getByTestId('resident-handoff-cap').fill('11');
    await editor.getByTestId('resident-handoff-cap').locator('xpath=ancestor::form').getByRole('button').click();
    await expect(cap).toHaveValue('11');

    await page.getByLabel('Account name', { exact: true }).fill('Unfinished local name');
    await cap.fill('13');
    await saveName('Remote account name');
    await expect(page.getByTestId('nav-account-name')).toHaveText('Remote account name');
    await expect(page.getByLabel('Account name', { exact: true })).toHaveValue('Unfinished local name');
    await expect(cap).toHaveValue('13');
    expect(partials.some((props) => props.includes('resident_handoff_cap'))).toBe(true);

    drop = true;
    await saveName('Missed account name');
    socket.close({ code: 1012, reason: 'Synthetic account configuration reconnect' });
    await expect(page.getByTestId('nav-account-name')).toHaveText('Missed account name', { timeout: 20_000 });
    drop = false;
    await expect(page.getByLabel('Account name', { exact: true })).toHaveValue('Unfinished local name');
    await expect(cap).toHaveValue('13');
    await page.screenshot({ path: testInfo.outputPath('account-config-drafts.png'), fullPage: true });

    // The same existing Account marker refreshes titles on the other settings pages.
    for (const path of ['interface', 'rooms']) {
      await page.goto(`${base}/${path}`);
      await saveName(`Updated on ${path}`);
      await expect(page.getByTestId('nav-account-name')).toHaveText(`Updated on ${path}`);
    }
  } finally {
    await editor.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
