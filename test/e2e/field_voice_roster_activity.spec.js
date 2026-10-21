import { expect, test } from '@playwright/test';

// Observe/drop actual server frames, never manufacture refreshes or page props.
async function observeLifecycle(page) {
  const state = { socket: null, drop: false, frames: [], dropped: [], confirmations: [], reloads: [] };
  await page.routeWebSocket('**/cable', (socket) => {
    state.socket = socket;
    socket.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      const model = message.identifier && JSON.parse(message.identifier).model;
      if (message.type === 'confirm_subscription') state.confirmations.push(model);
      if (message.message && ['FieldVoiceActivity', 'FieldRecording'].includes(model)) {
        state.frames.push({ model, payload: message.message });
      }
      if (state.drop && message.message) {
        state.dropped.push(model);
      } else {
        socket.send(raw);
      }
    });
  });
  page.on('request', (req) => {
    const props = req.headers()['x-inertia-partial-data'];
    if (props) state.reloads.push(props.split(','));
  });
  return state;
}

async function loginLifecycle(page, setup) {
  await page.goto('/login');
  await page.getByLabel(/email/i).fill(setup.primary_user.email);
  await page.getByLabel(/password/i).fill(setup.password);
  await page.getByRole('button', { name: /log in/i }).click();
  await expect(page).toHaveURL(/\/$/);
}

test('remembered lifecycle and missed socket events preserve roster and recording drafts', async ({
  page,
  browser,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `voice-lifecycle-${Date.now()}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  let editorContext;
  let detail;
  try {
    const recordingResponse = await request.post('/test/e2e/field_recording_fixture', {
      data: { account_id: setup.account_id, title: 'Synthetic lifecycle recording', speakers_ready: true },
    });
    expect(recordingResponse.ok()).toBe(true);
    const fixture = await recordingResponse.json();
    const produce = async (operation) => {
      const response = await request.post('/test/e2e/field_voice_lifecycle_fixture', {
        data: { account_id: setup.account_id, recording_param: fixture.recording_param, operation },
      });
      expect(response.ok()).toBe(true);
    };
    await produce('setup');
    const base = `/accounts/${setup.account_param}/field`;
    const rosterSocket = await observeLifecycle(page);
    await loginLifecycle(page, setup);
    await page.goto(`${base}/voices`);
    await expect.poll(() => rosterSocket.confirmations).toContain('FieldVoiceActivity');
    // The selected speaker's detail carries what was learned and the rename control.
    const row = page.getByTestId('voice-detail');
    await expect(row).toContainText('Name only');
    await row.getByRole('button', { name: 'Rename', exact: true }).click();
    const rename = page.getByRole('textbox', { name: 'Name', exact: true });
    await rename.fill('Unfinished lifecycle rename');

    detail = await page.context().newPage();
    const detailSocket = await observeLifecycle(detail);
    await detail.goto(`${base}/recordings/${fixture.recording_param}`);
    const initialProps = JSON.parse(await detail.locator('#app').getAttribute('data-page')).props;
    expect(initialProps.recognition_enabled).toBe(false);
    await expect.poll(() => detailSocket.confirmations).toContain('FieldRecording');
    await expect.poll(() => detailSocket.confirmations).toContain('FieldVoiceActivity');
    await detail.getByTestId('add-recording-notes').click();
    const notes = detail.locator('#recording-notes');
    await notes.fill('Unfinished lifecycle meeting notes');
    await detail.getByTestId('transcript-line').first().click();
    const line = detail.getByTestId('line-editor');
    await line.fill('Unfinished lifecycle transcript correction');
    const draftsSurvive = async () => {
      await expect(rename).toHaveValue('Unfinished lifecycle rename');
      await expect(notes).toHaveValue('Unfinished lifecycle meeting notes');
      await expect(line).toHaveValue('Unfinished lifecycle transcript correction');
    };

    // A separately authenticated, already-open browser context performs forget.
    editorContext = await browser.newContext();
    const editor = await editorContext.newPage();
    await loginLifecycle(editor, setup);
    await editor.goto(`${base}/voices`);
    await expect(editor.getByTestId('voice-row')).toContainText('Name only');
    await page.waitForLoadState('networkidle');
    await detail.waitForLoadState('networkidle');
    rosterSocket.reloads.length = 0;
    detailSocket.reloads.length = 0;
    const confirmations = [rosterSocket.confirmations.length, detailSocket.confirmations.length];

    const detailRefresh = () =>
      detail.waitForResponse((response) =>
        (response.request().headers()['x-inertia-partial-data'] || '').split(',').includes('voices')
      );
    let refreshed = detailRefresh();
    await produce('remember');
    expect((await refreshed).ok()).toBe(true);
    await expect(row).toContainText('Voice learned from 1 recording, 12 s');
    await expect(editor.getByTestId('voice-forget')).toBeVisible();
    await draftsSurvive();
    await page.waitForLoadState('networkidle');
    await detail.waitForLoadState('networkidle');
    expect(rosterSocket.reloads).toHaveLength(1);
    expect(rosterSocket.reloads[0].sort()).toEqual(['voices', 'recognise_voices', 'can_change_setting'].sort());
    // A print is roster state now: speaker cards don't show it, so the
    // transcript page reloads only its roster props.
    expect(detailSocket.reloads).toHaveLength(1);
    expect(detailSocket.reloads[0].sort()).toEqual(
      ['voices', 'members_without_voice', 'my_voice_id', 'recognition_enabled'].sort()
    );

    refreshed = detailRefresh();
    await produce('metadata');
    expect((await refreshed).ok()).toBe(true);
    await expect(row).toContainText('Voice learned from 2 recordings, 21 s');
    await draftsSurvive();

    refreshed = detailRefresh();
    editor.once('dialog', (dialog) => dialog.accept());
    await editor.getByTestId('voice-forget').click();
    expect((await refreshed).ok()).toBe(true);
    await expect(row).toContainText('Voice forgotten, not learning');
    await expect(editor.getByTestId('voice-forget')).toHaveCount(0);
    await expect(detail.getByTestId('speaker-card').first()).toContainText('Synthetic lifecycle voice');
    await draftsSurvive();
    await page.waitForLoadState('networkidle');
    await detail.waitForLoadState('networkidle');
    // Prop refreshes have not churned the dynamic subscriptions.
    expect([rosterSocket.confirmations.length, detailSocket.confirmations.length]).toEqual(confirmations);

    // Turn learning back on while connected, so the print the lost event
    // brings is the only thing a reconnect can show.
    refreshed = detailRefresh();
    await editor.getByTestId('voice-remember').click();
    expect((await refreshed).ok()).toBe(true);
    await expect(row).toContainText('Name only so far');
    await page.waitForLoadState('networkidle');
    await detail.waitForLoadState('networkidle');

    // Lose the only print-created event on BOTH readers, then reconnect with
    // no further write. Assert loss before closing so this cannot pass by luck.
    rosterSocket.drop = detailSocket.drop = true;
    const beforeReconnect = [rosterSocket.reloads.length, detailSocket.reloads.length];
    await produce('remember');
    await expect.poll(() => rosterSocket.dropped).toContain('FieldVoiceActivity');
    // The transcript page hears about a print through its roster stream only.
    await expect.poll(() => detailSocket.dropped).toContain('FieldVoiceActivity');
    expect(detailSocket.dropped).not.toContain('FieldRecording');
    await expect(editor.getByTestId('voice-forget')).toBeVisible();
    await expect(row).toContainText('Name only so far');
    expect([rosterSocket.reloads.length, detailSocket.reloads.length]).toEqual(beforeReconnect);
    rosterSocket.drop = detailSocket.drop = false;
    refreshed = detailRefresh();
    rosterSocket.socket.close({ code: 1012, reason: 'Synthetic lifecycle reconnect' });
    detailSocket.socket.close({ code: 1012, reason: 'Synthetic lifecycle reconnect' });
    expect((await refreshed).ok()).toBe(true);
    await expect(row).toContainText('Voice learned from 1 recording, 12 s', { timeout: 20_000 });
    await expect.poll(() => rosterSocket.confirmations.length).toBeGreaterThan(confirmations[0]);
    await expect.poll(() => detailSocket.confirmations.length).toBeGreaterThan(confirmations[1]);
    await draftsSurvive();
    await page.waitForLoadState('networkidle');
    await detail.waitForLoadState('networkidle');
    expect(rosterSocket.reloads.length - beforeReconnect[0]).toBe(1);
    expect(detailSocket.reloads.length - beforeReconnect[1]).toBe(1);

    for (const { model, payload } of [...rosterSocket.frames, ...detailSocket.frames]) {
      expect(payload).toEqual(
        model === 'FieldRecording' ? { action: 'refresh', prop: 'field_recording' } : { action: 'refresh' }
      );
    }
    await page.screenshot({ path: testInfo.outputPath('voice-lifecycle-roster-draft.png'), fullPage: true });
    await detail.screenshot({ path: testInfo.outputPath('voice-lifecycle-recording-drafts.png'), fullPage: true });
  } finally {
    await editorContext?.close();
    await detail?.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});

test('voice roster and open speaker picker catch changes without replacing drafts', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `voice-roster-${Date.now()}`;
  const setupResponse = await request.post('/test/e2e/setup', { data: { run_id: runId } });
  expect(setupResponse.ok()).toBe(true);
  const setup = await setupResponse.json();
  const fixtureResponse = await request.post('/test/e2e/field_recording_fixture', {
    data: { account_id: setup.account_id, title: 'Voice roster live', speakers_ready: true },
  });
  expect(fixtureResponse.ok()).toBe(true);
  const fixture = await fixtureResponse.json();
  let socket;
  let drop = false;
  let confirmed = false;
  await page.routeWebSocket('**/cable', (cable) => {
    socket = cable;
    cable.connectToServer().onMessage((raw) => {
      const message = JSON.parse(raw);
      if (message.type === 'confirm_subscription' && JSON.parse(message.identifier).model === 'FieldVoiceActivity')
        confirmed = true;
      if (!drop || !message.message) cable.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('voices')) reloads.push(props);
  });
  let editor;
  let detail;
  try {
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}/field`;
    const recording = `${base}/recordings/${fixture.recording_param}`;
    await page.goto(`${base}/voices`);
    await expect.poll(() => confirmed).toBe(true);
    await expect(page.getByText(/No voices yet/)).toBeVisible();
    editor = await page.context().newPage();
    await editor.goto(recording);
    await editor.getByTestId('speaker-chip').first().click();
    await editor.getByPlaceholder('Their name').fill('Live voice');
    await editor.getByRole('button', { name: 'Name', exact: true }).click();
    await expect(page.getByTestId('voice-row')).toContainText('Live voice');
    await page.getByRole('button', { name: 'Rename', exact: true }).click();
    const renameDraft = page.getByRole('textbox', { name: 'Name', exact: true });
    await renameDraft.fill('Unfinished roster rename');

    detail = await page.context().newPage();
    await detail.goto(recording);
    await detail.getByTestId('add-recording-notes').click();
    const notes = detail.locator('#recording-notes');
    await notes.fill('Unfinished meeting notes');
    await detail.getByTestId('speaker-chip').last().click();
    const pickerDraft = detail.getByPlaceholder('Their name');
    await pickerDraft.fill('Unfinished new speaker');
    await editor.goto(`${base}/voices`);
    await editor.getByRole('button', { name: 'Rename', exact: true }).click();
    await editor.getByRole('textbox', { name: 'Name', exact: true }).fill('Remote voice');
    await editor.getByRole('button', { name: 'Save', exact: true }).click();
    await expect(detail.getByRole('button', { name: 'Remote voice', exact: true })).toBeVisible();
    await expect(pickerDraft).toHaveValue('Unfinished new speaker');
    await expect(notes).toHaveValue('Unfinished meeting notes');
    await expect(renameDraft).toHaveValue('Unfinished roster rename');
    await detail.getByRole('button', { name: 'Remote voice', exact: true }).click();
    await expect(page.getByTestId('voice-row')).toContainText('named in 2 speakers');
    await expect(renameDraft).toHaveValue('Unfinished roster rename');
    await page.waitForLoadState('networkidle');
    // FieldRecording account hints include the current navbar account projection.
    expect([...reloads.at(-1)].sort()).toEqual(
      [
        'voices',
        'recognise_voices',
        'can_change_setting',
        'account',
        'accounts',
        'expired_subscriptions',
        'is_account_admin',
      ].sort()
    );

    drop = true;
    await editor.getByRole('button', { name: 'Rename', exact: true }).click();
    await editor.getByRole('textbox', { name: 'Name', exact: true }).fill('After reconnect');
    await editor.getByRole('button', { name: 'Save', exact: true }).click();
    socket.close({ code: 1012, reason: 'Synthetic voice roster reconnect' });
    drop = false;
    await expect(renameDraft).toHaveValue('Unfinished roster rename');
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(page.getByTestId('voice-row')).toContainText('After reconnect', { timeout: 20_000 });
    await page.waitForLoadState('networkidle');
    // Reconnect also catches up the layout's room/account/attention lanes.
    expect(reloads.at(-1)).toEqual(expect.arrayContaining(['voices', 'recognise_voices', 'can_change_setting']));
    page.on('dialog', (dialog) => dialog.accept());
    await editor.getByRole('button', { name: 'Rename', exact: true }).click();
    await page.getByRole('button', { name: 'Rename', exact: true }).click();
    await page.getByRole('textbox', { name: 'Name', exact: true }).fill('Deleted draft');
    editor.once('dialog', (dialog) => dialog.accept());
    // Leave the editor's own rename mode so its delete control is visible.
    await editor.getByRole('button', { name: 'Cancel', exact: true }).click();
    await editor.getByRole('button', { name: 'Delete name', exact: true }).click();
    await expect(page.getByText(/No voices yet/)).toBeVisible();
    await expect(page.getByRole('textbox', { name: 'Name', exact: true })).toHaveCount(0);
    await expect(notes).toHaveValue('Unfinished meeting notes');
    await page.screenshot({ path: testInfo.outputPath('voice-roster-live.png'), fullPage: true });
  } finally {
    await editor?.close();
    await detail?.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
