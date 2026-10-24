import { expect, test } from '@playwright/test';

test('two open glossaries follow terms and built-in names while preserving drafts and catching missed events', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `glossary-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const mutate = async (operation, extra = {}) => {
    const result = await request.post('/test/e2e/glossary_fixture', {
      data: { account_id: setup.account_id, operation, ...extra },
    });
    expect(result.ok()).toBe(true);
    return result;
  };
  const confirmed = new Set();
  const hints = [];
  let socket;
  let drop = false;
  await page.routeWebSocket('**/cable', (cable) => {
    socket = cable;
    cable.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.identifier) {
        const model = JSON.parse(message.identifier).model;
        if (message.type === 'confirm_subscription') confirmed.add(model);
        if (message.message && ['GlossaryActivity', 'HomeResidentRoster'].includes(model)) hints.push(message.message);
      }
      if (!drop || !message.message) cable.send(raw);
    });
  });
  const partials = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('terms') || props.includes('removed')) partials.push(props);
  });
  const editor = await page.context().newPage();
  const row = (target, word) => target.locator(`[data-glossary-term="${word}"]`);
  const input = (target) => target.getByRole('textbox', { name: 'Word or phrase' });
  const add = async (word) => {
    await input(editor).fill(word);
    await editor.getByRole('button', { name: 'Add', exact: true }).click();
    await expect(input(editor)).toHaveValue('');
    await expect(row(page, word)).toBeVisible();
  };
  let originalSiteName;
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const path = `/accounts/${setup.account_param}/glossary`;
    await page.goto(path);
    await editor.goto(path);
    await expect.poll(() => confirmed.has('GlossaryActivity') && confirmed.has('HomeResidentRoster')).toBe(true);
    await input(page).fill('Unsent local vocabulary');
    await add('Shared vocabulary');
    await row(editor, 'Shared vocabulary').getByTitle('Pin', { exact: true }).click();
    await expect(row(page, 'Shared vocabulary')).toContainText('Pinned');
    await row(editor, 'Shared vocabulary').getByTitle('Unpin', { exact: true }).click();
    await expect(row(page, 'Shared vocabulary')).not.toContainText('Pinned');
    await row(editor, 'Shared vocabulary').getByTitle('Remove', { exact: true }).click();
    await expect(row(page, 'Shared vocabulary')).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Restore' })).toBeVisible();
    await editor.getByRole('button', { name: 'Restore' }).click();
    await expect(row(page, 'Shared vocabulary')).toBeVisible();

    await mutate('create');
    await expect(row(page, 'Glossary arrival')).toBeVisible();
    await page.waitForLoadState('networkidle');
    await mutate('rename');
    await expect(row(page, 'Glossary renamed')).toBeVisible();
    await expect(row(page, 'Glossary arrival')).toHaveCount(0);
    expect(partials.at(-1)).toContain('terms');
    expect(partials.at(-1)).not.toContain('removed');
    await row(editor, 'Glossary renamed').getByTitle('Remove', { exact: true }).click();
    await expect(row(page, 'Glossary renamed')).toHaveCount(0);
    await editor.getByRole('button', { name: 'Restore' }).click();
    await expect(row(page, 'Glossary renamed')).toBeVisible();

    const renamedSite = await mutate('site_name', { name: 'Glossary house' });
    originalSiteName = (await renamedSite.json()).previous;
    await expect(row(page, 'Glossary house')).toBeVisible();
    await expect(input(page)).toHaveValue('Unsent local vocabulary');
    await page.waitForLoadState('networkidle');
    const beforeHealth = partials.length;
    await mutate('health');
    await page.waitForTimeout(900); // negative assertion beyond shared debounce
    expect(partials).toHaveLength(beforeHealth);

    drop = true;
    await input(editor).fill('Missed vocabulary');
    await editor.getByRole('button', { name: 'Add', exact: true }).click();
    await expect(row(editor, 'Missed vocabulary')).toBeVisible();
    socket.close({ code: 1012, reason: 'Synthetic glossary reconnect' });
    await expect(row(page, 'Missed vocabulary')).toBeVisible({ timeout: 20_000 });
    drop = false;
    await expect(input(page)).toHaveValue('Unsent local vocabulary');

    let release;
    let intercepted;
    const arrived = new Promise((resolve) => (intercepted = resolve));
    const held = new Promise((resolve) => (release = resolve));
    await page.route(`**${path}`, async (route) => {
      if (route.request().method() === 'POST') {
        intercepted();
        await held;
      }
      await route.continue();
    });
    await input(page).fill('Submitted vocabulary');
    await page.getByRole('button', { name: 'Add', exact: true }).click();
    await arrived;
    await input(page).fill('Newer unsent vocabulary');
    release();
    await expect(row(page, 'Submitted vocabulary')).toBeVisible();
    await expect(input(page)).toHaveValue('Newer unsent vocabulary');
    // Shared debounce may union these with the existing navbar's catch-up.
    const allowed = [
      'terms',
      'removed',
      'accounts',
      'expired_subscriptions',
      'account',
      'is_account_admin',
      'reply_attention',
      'room_activity',
      'rooms',
      'current_room',
      'main_room_name',
    ];
    for (const props of partials) expect(props.every((prop) => allowed.includes(prop))).toBe(true);
    expect(confirmed.has('Agent')).toBe(false);
    expect(confirmed.has('Setting')).toBe(false);
    for (const hint of hints) expect(hint).toEqual({ action: 'refresh' });
    expect(partials.length).toBeLessThan(35);
    await page.screenshot({ path: testInfo.outputPath('glossary-live-draft.png'), fullPage: true });
  } finally {
    if (originalSiteName) await mutate('site_name', { name: originalSiteName });
    await editor.close();
    const cleanup = await request.post('/test/e2e/cleanup', { data: { run_id: runId } });
    expect(cleanup.ok()).toBe(true);
  }
});
