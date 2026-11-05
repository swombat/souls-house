import { expect, test } from '@playwright/test';

// #748: on Daniel's phone voice mode never read a reply, and no reply text
// appeared until End. The panel held the recording guard for the whole
// conversation, which cancelled every background Inertia reload, so the
// messages broadcast never reached the page. This checks the real wiring
// (Rails broadcast, ActionCable, Inertia partial reload, the mounted panel,
// the reply picker and the player) rather than the unit tests' mocks.
// The fake microphone is muted once listening so its test tone never opens
// a turn. Nothing leaves the machine: the transcription session the panel
// asks for at mount is refused in the browser (a deterministic 503, which the
// panel only reports as a note), and speech audio is stubbed.

test.use({
  permissions: ['microphone'],
  launchOptions: {
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      '--autoplay-policy=no-user-gesture-required',
    ],
  },
});

// A tenth of a second of 8 kHz mono silence.
function silentWav() {
  const samples = 800;
  const buffer = Buffer.alloc(44 + samples, 128);
  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(36 + samples, 4);
  buffer.write('WAVEfmt ', 8);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(8000, 24);
  buffer.writeUInt32LE(8000, 28);
  buffer.writeUInt16LE(1, 32);
  buffer.writeUInt16LE(8, 34);
  buffer.write('data', 36);
  buffer.writeUInt32LE(samples, 40);
  return buffer;
}

test.describe('voice mode replies', () => {
  let setup;

  test.beforeEach(async ({ page, request }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `voice-mode-replies-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();
  });

  async function openVoiceMode({ page, request, engine }) {
    const voice = await request.post('/test/e2e/voice_mode_fixture', {
      data: { account_id: setup.account_id, ...(engine ? { speech_engine: engine } : {}) },
    });
    expect(voice.ok()).toBe(true);
    expect((await voice.json()).voice_mode).toMatchObject({ offered: true, available: true });

    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
  }

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  test('a reply that lands while the panel is open reaches the page, is shown, and is fetched for reading', async ({
    page,
    request,
  }) => {
    // The ElevenLabs engine: the player asks the server for each reply's audio.
    await openVoiceMode({ page, request, engine: 'elevenlabs' });
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 2, prefix: 'Before voice mode', resident_count: 1 },
      })
    ).json();

    const speech = [];
    await page.route('**/messages/*/speech', (route) => {
      speech.push(new URL(route.request().url()).pathname);
      return route.fulfill({ status: 200, contentType: 'audio/wav', body: silentWav() });
    });

    const sessions = [];
    await page.route('**/voice_mode_session', (route) => {
      sessions.push(route.request().method());
      return route.fulfill({ status: 503, json: { error: 'No transcription in this test.' } });
    });
    // Headless Chromium here never settles audioWorklet.addModule on a blob
    // URL, so capture takes its ScriptProcessor fallback (the same detector).
    await page.addInitScript(() => {
      delete BaseAudioContext.prototype.audioWorklet;
    });
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    await page.getByTestId('voice-mode-button').click();
    const panel = page.getByTestId('voice-mode-panel');
    await expect(panel).toBeVisible();
    await expect(page.getByTestId('voice-mode-status')).toHaveText(/Waiting for you/);
    await page.getByRole('button', { name: 'Mute' }).click();
    await expect(page.getByTestId('voice-mode-status')).toHaveText(/Muted/);

    const landed = await (
      await request.post('/test/e2e/assistant_message', {
        data: { chat_id: fixture.chat_id, content: 'Landed while voice mode was open' },
      })
    ).json();

    // The broadcast reload reaches the page while the panel is still mounted...
    await expect(page.getByText('Landed while voice mode was open').first()).toBeVisible({ timeout: 10_000 });
    await expect(panel).toBeVisible();
    // ...and the picker hands it to the player, which asks the server for its audio.
    await expect.poll(() => speech, { timeout: 10_000 }).toContain(`/messages/${landed.message_id}/speech`);
    expect(speech.filter((path) => path.includes(landed.message_id))).toHaveLength(1);
    expect(sessions.length).toBeGreaterThan(0);
    expect(sessions.every((method) => method === 'POST')).toBe(true);
  });
  // Phonon, the default engine, runs in the browser. This headless Chromium
  // has no WebGPU adapter, so the panel must say why, and the reply must not
  // be read by ElevenLabs instead (no fallback, jEDyze): no /speech request.
  test('under Phonon a browser without WebGPU says so in the panel and never falls back to ElevenLabs', async ({
    page,
    request,
  }) => {
    await openVoiceMode({ page, request });
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: 'Before voice mode', resident_count: 1 },
      })
    ).json();

    const speech = [];
    const texts = [];
    await page.route('**/messages/*/speech', (route) => {
      speech.push(route.request().url());
      return route.fulfill({ status: 200, contentType: 'audio/wav', body: silentWav() });
    });
    page.on('request', (req) => {
      if (/\/messages\/[^/]+\/speech_text/.test(req.url())) texts.push(new URL(req.url()).pathname);
    });
    await page.route('**/voice_mode_session', (route) =>
      route.fulfill({ status: 503, json: { error: 'No transcription in this test.' } })
    );
    await page.addInitScript(() => {
      delete BaseAudioContext.prototype.audioWorklet;
    });
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    await page.getByTestId('voice-mode-button').click();
    await expect(page.getByTestId('voice-mode-panel')).toBeVisible();
    await page.getByRole('button', { name: 'Mute' }).click();

    const landed = await (
      await request.post('/test/e2e/assistant_message', {
        data: { chat_id: fixture.chat_id, content: 'Landed for Phonon' },
      })
    ).json();

    await expect(page.getByText('Landed for Phonon').first()).toBeVisible({ timeout: 10_000 });
    await expect.poll(() => texts, { timeout: 10_000 }).toContain(`/messages/${landed.message_id}/speech_text`);
    await expect(page.getByTestId('voice-mode-phonon-status')).toHaveText(/needs WebGPU/, { timeout: 10_000 });
    expect(speech).toEqual([]);
  });
});
