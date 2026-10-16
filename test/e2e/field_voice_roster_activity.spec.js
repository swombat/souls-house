import { expect, test } from '@playwright/test';

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
    expect([...reloads.at(-1)].sort()).toEqual(['voices', 'recognise_voices', 'can_change_setting'].sort());
    page.on('dialog', (dialog) => dialog.accept());
    await editor.getByRole('button', { name: 'Rename', exact: true }).click();
    await page.getByRole('button', { name: 'Rename', exact: true }).click();
    await page.getByRole('textbox', { name: 'Name', exact: true }).fill('Deleted draft');
    editor.once('dialog', (dialog) => dialog.accept());
    // Leave the editor's own rename mode so its delete control is visible.
    await editor.getByRole('button', { name: 'Cancel', exact: true }).click();
    await editor.getByRole('button', { name: 'Delete name', exact: true }).click();
    await expect(page.getByText(/No voices yet/)).toBeVisible();
    await expect(page.getByRole('textbox')).toHaveCount(0);
    await expect(notes).toHaveValue('Unfinished meeting notes');
    await page.screenshot({ path: testInfo.outputPath('voice-roster-live.png'), fullPage: true });
  } finally {
    await editor?.close();
    await detail?.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
