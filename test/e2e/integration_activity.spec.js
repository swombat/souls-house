import { expect, test } from '@playwright/test';

test('connector chat counts follow real events and reconnect without replacing drafts', async ({
  page,
  browser,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `comms-count-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, resident_dashboard: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  const mutate = async (operation) => {
    const result = await request.post('/test/e2e/comms_count_fixture', {
      data: { account_id: setup.account_id, operation },
    });
    expect(result.ok(), `${operation}: HTTP ${result.status()}`).toBe(true);
  };
  const otherContext = await browser.newContext({ baseURL: testInfo.project.use.baseURL });
  const resident = await otherContext.newPage();
  // Playwright's per-page WebSocket interception installs a context binding.
  // Independent contexts avoid overlapping page bindings breaking WebSocket
  // construction in another tab ("binding is not a function").
  const draftContext = await browser.newContext({ baseURL: testInfo.project.use.baseURL });
  const draftView = await draftContext.newPage();
  const readers = await Promise.all(
    [page, resident, draftView].map(async (view) => {
      const state = { markers: [], reloads: [], confirmations: 0, cable: null, drop: false };
      await view.routeWebSocket('**/cable', (socket) => {
        state.cable = socket;
        const server = socket.connectToServer();
        server.onMessage((raw) => {
          const frame = JSON.parse(raw);
          if (frame.identifier && JSON.parse(frame.identifier).model === 'IntegrationStatus') {
            if (frame.type === 'confirm_subscription') state.confirmations += 1;
            if (frame.message) state.markers.push(frame.message);
          }
          if (!state.drop || !frame.message) socket.send(raw);
        });
      });
      view.on('response', async (result) => {
        const partial = result.request().headers()['x-inertia-partial-data'];
        if (
          result.ok() &&
          result.headers()['content-type']?.includes('application/json') &&
          partial?.split(',').some((key) => ['connections', 'service_connections'].includes(key))
        ) {
          state.reloads.push({ partial, body: await result.json() });
        }
      });
      return state;
    })
  );
  try {
    await mutate('prepare');
    const base = `/accounts/${setup.account_param}`;
    for (const view of [page, resident, draftView]) {
      await view.goto('/login');
      await view.getByLabel(/email/i).fill(setup.primary_user.email);
      await view.getByLabel(/password/i).fill(setup.password);
      await view.getByRole('button', { name: /log in/i }).click();
      await expect(view).toHaveURL(/\/$/);
    }
    await page.goto(`${base}/integrations`);
    const row = page.getByRole('article').filter({ hasText: 'Connector counts' });
    await row.getByRole('button', { name: 'Show details for Connector counts', exact: true }).click();
    // Focused provider setup hides other providers' rows, so keep its
    // unsaved choice in a separate open view rather than hiding the count.
    await draftView.goto(`${base}/integrations?connect=google_workspace`);
    await draftView.getByRole('radio', { name: /The whole account/ }).check();
    await resident.goto(`${base}/residents/${setup.agents[0].id}/edit`);
    await resident.getByLabel('Display name', { exact: true }).fill('Unsubmitted count-refresh draft');
    for (const reader of readers) await expect.poll(() => reader.confirmations).toBe(1);
    // All page/nav subscriptions do an initial catch-up. Let that shared
    // debounce finish before checking the count marker's narrower prop set.
    // networkidle alone can precede the subscription's debounced request.
    for (const [index, prop] of ['connections', 'service_connections', 'connections'].entries()) {
      await expect
        .poll(() => {
          const comms = readers[index].reloads
            .at(-1)
            ?.body.props[prop]?.find((connection) => connection.label === 'Connector counts')?.comms;
          return comms && [comms.synced_chats, comms.chats];
        })
        .toEqual([0, 0]);
    }
    await Promise.all([page, resident, draftView].map((view) => view.waitForLoadState('networkidle')));

    const assertCounts = async (synced, total, reconnected = false) => {
      await expect(row.getByTestId('telegram-status')).toContainText(`${synced} of ${total} chats synced`);
      await expect
        .poll(() => {
          const connections = readers[1].reloads.at(-1)?.body.props.service_connections;
          const comms = connections?.find((connection) => connection.label === 'Connector counts')?.comms;
          return comms && [comms.synced_chats, comms.chats];
        })
        .toEqual([synced, total]);
      await expect
        .poll(() => {
          const comms = readers[2].reloads
            .at(-1)
            ?.body.props.connections.find((connection) => connection.label === 'Connector counts')?.comms;
          return comms && [comms.synced_chats, comms.chats];
        })
        .toEqual([synced, total]);
      await expect(draftView.getByRole('radio', { name: /The whole account/ })).toBeChecked();
      await expect(row.getByRole('button', { name: 'Hide details for Connector counts', exact: true })).toBeVisible();
      await expect(resident.getByLabel('Display name', { exact: true })).toHaveValue('Unsubmitted count-refresh draft');
      const accountProps = ['can_manage_account', 'connections', 'services'];
      // Closing the socket reconnects every navbar/page stream, not just
      // IntegrationStatus. Their intentional catch-ups share one debounce.
      if (reconnected)
        accountProps.push(
          'account',
          'accounts',
          'current_room',
          'expired_subscriptions',
          'is_account_admin',
          'main_room_name',
          'reply_attention',
          'room_activity',
          'rooms'
        );
      expect(readers[0].reloads.at(-1).partial.split(',').sort()).toEqual(accountProps.sort());
      expect(readers[1].reloads.at(-1).partial).toBe('service_connections');
      expect(readers[1].confirmations).toBe(1);
      expect(readers[2].confirmations).toBe(1);
    };
    await expect(row.getByTestId('telegram-status')).toContainText('0 of 0 chats synced');
    await mutate('arrive'); // message.upsert implicitly creates the first chat.
    await assertCounts(1, 1);
    await mutate('flip');
    await assertCounts(0, 1);
    await page.waitForLoadState('networkidle');
    await resident.waitForLoadState('networkidle');
    await draftView.waitForLoadState('networkidle');
    const beforeQuiet = readers.map((reader) => [reader.markers.length, reader.reloads.length]);
    await mutate('checkpoint');
    await mutate('message');
    await page.waitForTimeout(1200); // Beyond cable polling and the shared reload debounce.
    expect(readers.map((reader) => [reader.markers.length, reader.reloads.length])).toEqual(beforeQuiet);
    await assertCounts(0, 1);
    await mutate('remove');
    await assertCounts(0, 0);

    // Suppress the sole event on the account reader; a second real context
    // witnesses its commit before reconnect reconciles the missed count.
    readers[0].drop = true;
    await mutate('late');
    await expect
      .poll(
        () =>
          readers[1].reloads
            .at(-1)
            ?.body.props.service_connections.find((connection) => connection.label === 'Connector counts')?.comms.chats
      )
      .toBe(1);
    await expect(row.getByTestId('telegram-status')).toContainText('0 of 0 chats synced');
    readers[0].cable.close({ code: 1012, reason: 'Synthetic missed-count reconnect' });
    await expect.poll(() => readers[0].confirmations, { timeout: 20_000 }).toBe(2);
    await assertCounts(1, 1, true);
    readers[0].drop = false;
    for (const reader of readers) {
      expect(reader.markers.length).toBeGreaterThanOrEqual(4);
      expect(reader.markers.every((marker) => JSON.stringify(marker) === '{"action":"refresh"}')).toBe(true);
    }
    await page.screenshot({ path: testInfo.outputPath('comms-counts-reconnected.png'), fullPage: true });
  } finally {
    await draftContext.close();
    await otherContext.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});

test('open integration pages and resident tabs update without losing a connect draft', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `integration-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', {
    data: { run_id: runId, resident_dashboard: true, integrations: true },
  });
  expect(response.ok()).toBe(true);
  const setup = await response.json();
  let cable;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (socket) => {
    cable = socket;
    const server = socket.connectToServer();
    server.onMessage((raw) => {
      const data = JSON.parse(raw);
      if (data.type === 'confirm_subscription' && JSON.parse(data.identifier).model === 'IntegrationStatus')
        confirmed = true;
      if (!drop || !data.message) socket.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    if ((req.headers()['x-inertia-partial-data'] || '').split(',').includes('connections'))
      reloads.push(req.headers()['x-inertia-partial-data']);
  });
  const editor = await page.context().newPage();
  const resident = await page.context().newPage();
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}`;
    await page.goto(`${base}/integrations`);
    await expect.poll(() => confirmed).toBe(true);
    const readerRow = page.getByRole('article').filter({ hasText: 'Team files' });
    await readerRow.getByRole('button', { name: 'Show details for Team files', exact: true }).click();
    await editor.goto(`${base}/integrations`);
    const editorRow = editor.getByRole('article').filter({ hasText: 'Team files' });
    await editorRow.getByRole('button', { name: 'Show details for Team files', exact: true }).click();
    const name = setup.agents[0].name;
    await resident.goto(`${base}/residents/${setup.agents[0].id}/edit?tab=integrations`);
    await editorRow.getByRole('switch', { name: `Enable Team files for ${name}`, exact: true }).click();
    await expect(readerRow.getByRole('switch', { name: `Disable Team files for ${name}`, exact: true })).toBeChecked();
    await expect(readerRow.getByRole('button', { name: 'Hide details for Team files', exact: true })).toBeVisible();
    await expect(
      resident
        .locator('.p-5')
        .filter({ has: resident.getByRole('heading', { name: 'Team files', exact: true }) })
        .getByRole('button', { name: 'Disable', exact: true })
    ).toBeVisible();
    await page.waitForLoadState('networkidle');
    const beforeChat = reloads.length;
    expect(
      (
        await request.post('/test/e2e/field_activity_fixture', {
          data: { account_id: setup.account_id, operation: 'chat' },
        })
      ).ok()
    ).toBe(true);
    await page.waitForTimeout(900); // negative assertion beyond the shared debounce
    expect(reloads).toHaveLength(beforeChat);

    // A sole missed event is recovered on reconnect without navigating.
    drop = true;
    await editorRow.getByLabel('Turn on for new residents automatically').check();
    await expect(editorRow.getByLabel('Turn on for new residents automatically')).toBeChecked();
    cable.close({ code: 1012, reason: 'Synthetic integration reconnect' });
    await expect(readerRow.getByLabel('Turn on for new residents automatically')).toBeChecked({
      timeout: 20_000,
    });
    drop = false;
    await page.screenshot({ path: testInfo.outputPath('integrations-live.png'), fullPage: true });

    await page.goto(`${base}/integrations?connect=google_workspace`);
    await page.getByRole('radio', { name: /The whole account/ }).check();
    const before = reloads.length;
    await editorRow.getByRole('switch', { name: `Disable Team files for ${name}`, exact: true }).click();
    await expect.poll(() => reloads.length).toBeGreaterThan(before);
    await expect(page.getByRole('radio', { name: /The whole account/ })).toBeChecked();
    await expect(page).toHaveURL(/connect=google_workspace/);
    expect(reloads.at(-1).split(',')).not.toContain('focused_service');
  } finally {
    await editor.close();
    await resident.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
