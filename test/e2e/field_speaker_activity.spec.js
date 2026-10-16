import { expect, test } from '@playwright/test';

test('speaker decisions reach open recording and Field pages without losing notes', async ({
  page,
  request,
}, testInfo) => {
  test.setTimeout(120_000);
  const runId = `speaker-live-${Date.now()}`;
  const response = await request.post('/test/e2e/setup', { data: { run_id: runId } });
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
      if (data.type === 'confirm_subscription' && JSON.parse(data.identifier).model === 'FieldRecording')
        confirmed = true;
      if (!drop || !data.message) socket.send(raw);
    });
  });
  const reloads = [];
  page.on('request', (req) => {
    const props = (req.headers()['x-inertia-partial-data'] || '').split(',');
    if (props.includes('speakers')) reloads.push(props);
  });
  const editor = await page.context().newPage();
  const field = await page.context().newPage();
  const fieldReloads = [];
  field.on('request', (req) => {
    if ((req.headers()['x-inertia-partial-data'] || '').split(',').includes('items')) fieldReloads.push(req.url());
  });
  try {
    const fixture = await request.post('/test/e2e/field_recording_fixture', {
      data: { account_id: setup.account_id, title: 'Speakers live', speakers_ready: true },
    });
    expect(fixture.ok()).toBe(true);
    const { recording_param: recording } = await fixture.json();
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /log in/i }).click();
    await expect(page).toHaveURL(/\/$/);
    const base = `/accounts/${setup.account_param}/field`;
    const detail = `${base}/recordings/${recording}`;
    await page.goto(detail);
    await expect.poll(() => confirmed).toBe(true);
    await editor.goto(detail);
    await field.goto(`${base}?tab=recordings`);
    const badge = field.getByTestId('field-unnamed-speakers');
    await expect(badge).toHaveAttribute('aria-label', '2 speakers to name');
    await page.getByTestId('add-recording-notes').click();
    const draft = page.locator('#recording-notes');
    await draft.fill('Keep my unfinished meeting notes.');
    const readerCard = page.getByTestId('speaker-card').first();
    const editorCard = editor.getByTestId('speaker-card').first();
    await editorCard.getByTestId('speaker-dismiss').click();
    await editor.getByTestId('speaker-ignore').click();
    await expect(readerCard).toHaveAttribute('data-ignored', 'noise');
    await expect(badge).toHaveAttribute('aria-label', '1 speaker to name');
    await expect(draft).toHaveValue('Keep my unfinished meeting notes.');

    await page.waitForLoadState('networkidle');
    const beforeReason = reloads.length;
    await editorCard.getByTestId('speaker-switch-dismissal').click();
    await expect(readerCard).toHaveAttribute('data-ignored', 'anonymous');
    await page.waitForLoadState('networkidle');
    expect(reloads.length - beforeReason).toBeLessThanOrEqual(2);
    await expect(draft).toHaveValue('Keep my unfinished meeting notes.');

    // Lose the only Undo event, then reconnect with no subsequent write.
    drop = true;
    await editorCard.getByTestId('speaker-unignore').click();
    await expect(editorCard).not.toHaveAttribute('data-ignored');
    cable.close({ code: 1012, reason: 'Synthetic speaker reconnect' });
    await expect(readerCard).not.toHaveAttribute('data-ignored', { timeout: 20_000 });
    drop = false;
    await expect(badge).toHaveAttribute('aria-label', '2 speakers to name');
    await expect(draft).toHaveValue('Keep my unfinished meeting notes.');

    await page.waitForLoadState('networkidle');
    await field.waitForLoadState('networkidle');
    const beforeChat = reloads.length;
    const beforeFieldChat = fieldReloads.length;
    expect(
      (
        await request.post('/test/e2e/field_activity_fixture', {
          data: { account_id: setup.account_id, operation: 'chat' },
        })
      ).ok()
    ).toBe(true);
    await page.waitForTimeout(900); // negative assertion beyond the shared debounce
    expect(reloads).toHaveLength(beforeChat);
    expect(fieldReloads).toHaveLength(beforeFieldChat);
    await page.screenshot({ path: testInfo.outputPath('speaker-live-draft.png'), fullPage: true });
  } finally {
    await editor.close();
    await field.close();
    expect((await request.post('/test/e2e/cleanup', { data: { run_id: runId } })).ok()).toBe(true);
  }
});
