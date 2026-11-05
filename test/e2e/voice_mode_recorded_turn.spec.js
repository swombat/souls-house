import { expect, test } from '@playwright/test';
import { writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// #770: since #761 the panel sends every clean turn with its recording
// (audio_signed_id), and the server refused exactly that send ("Voice mode
// keeps no recording"), so a clean turn never arrived; only the rough
// fallback did. The panel's unit tests stub the POST, so CI stayed green.
// This drives one real spoken turn through the mounted panel and lets its
// send reach Rails unstubbed. The microphone is a file: a second of quiet,
// a second of tone, then quiet, so the page's own detector opens one turn
// and closes it. The transcriber socket and the ElevenLabs upload are faked
// in the browser (nothing leaves the machine); the upload answers with a
// recording the house really stored, as Chats::TranscriptionsController does.

// 16-bit mono PCM: 1 s silence, 1 s 440 Hz tone, 5 s silence.
function turnWav() {
  const rate = 16_000;
  const seconds = [1, 1, 5];
  const total = rate * seconds.reduce((a, b) => a + b, 0);
  const buffer = Buffer.alloc(44 + total * 2);
  buffer.write('RIFF', 0);
  buffer.writeUInt32LE(36 + total * 2, 4);
  buffer.write('WAVEfmt ', 8);
  buffer.writeUInt32LE(16, 16);
  buffer.writeUInt16LE(1, 20);
  buffer.writeUInt16LE(1, 22);
  buffer.writeUInt32LE(rate, 24);
  buffer.writeUInt32LE(rate * 2, 28);
  buffer.writeUInt16LE(2, 32);
  buffer.writeUInt16LE(16, 34);
  buffer.write('data', 36);
  buffer.writeUInt32LE(total * 2, 40);
  for (let i = rate; i < rate * 2; i++) {
    buffer.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 12_000), 44 + i * 2);
  }
  return buffer;
}

const micFile = join(tmpdir(), `voice-mode-turn-${process.pid}.wav`);
writeFileSync(micFile, turnWav());

test.use({
  permissions: ['microphone'],
  launchOptions: {
    args: [
      '--use-fake-ui-for-media-stream',
      '--use-fake-device-for-media-stream',
      `--use-file-for-fake-audio-capture=${micFile}`,
      '--autoplay-policy=no-user-gesture-required',
    ],
  },
});

test.describe('voice mode recorded turn', () => {
  let setup;

  test.beforeEach(async ({ page, request }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `voice-mode-recorded-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();
    const voice = await request.post('/test/e2e/voice_mode_fixture', { data: { account_id: setup.account_id } });
    expect(voice.ok()).toBe(true);

    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
  });

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  test('a clean turn is sent with its recording and the house accepts it', async ({ page, request }) => {
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: 'Before voice mode', resident_count: 1 },
      })
    ).json();
    const { signed_id: recording } = await (await request.post('/test/e2e/audio_blob')).json();

    await page.route('**/voice_mode_session', (route) =>
      route.fulfill({ json: { client_secret: 'ek_e2e', socket_url: 'wss://transcriber.e2e.invalid/realtime' } })
    );
    // The live transcriber: acknowledge each commit and give a rough caption.
    let item = 0;
    await page.routeWebSocket('wss://transcriber.e2e.invalid/**', (ws) => {
      ws.onMessage((raw) => {
        const event = JSON.parse(String(raw));
        if (event.type !== 'input_audio_buffer.commit') return;
        const id = `item_${++item}`;
        ws.send(JSON.stringify({ type: 'input_audio_buffer.committed', item_id: id }));
        ws.send(
          JSON.stringify({
            type: 'conversation.item.input_audio_transcription.completed',
            item_id: id,
            transcript: 'rough words',
          })
        );
      });
    });
    // ElevenLabs, as the house reports it: clean text and the stored recording.
    let uploads = 0;
    await page.route('**/chats/*/transcription', (route) => {
      if (route.request().method() !== 'POST') return route.fallback();
      uploads += 1;
      return route.fulfill({ json: { text: 'The recorded turn reaches the house', audio_signed_id: recording } });
    });
    await page.addInitScript(() => {
      delete BaseAudioContext.prototype.audioWorklet;
    });

    const sent = page.waitForResponse(
      (response) =>
        response.request().method() === 'POST' && /\/chats\/[^/]+\/messages$/.test(new URL(response.url()).pathname),
      { timeout: 20_000 }
    );
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    await page.getByTestId('voice-mode-button').click();
    await expect(page.getByTestId('voice-mode-panel')).toBeVisible();

    const response = await sent;
    const form = response.request().postDataBuffer()?.toString() || '';
    expect(form).toContain('name="audio_signed_id"');
    expect(uploads).toBe(1);
    expect(response.status(), await response.text()).toBe(201);
    await page.getByRole('button', { name: 'Mute' }).click();

    await expect(page.getByText('The recorded turn reaches the house').first()).toBeVisible({ timeout: 10_000 });
    await expect(page.getByTestId('voice-mode-panel')).not.toContainText(/keeps no recording/);
  });

  // jMapOj: Daniel's "five, six, seven, eight" showed on screen and never
  // arrived; a send that failed went to the console. Now the turn is held in
  // the panel and Retry delivers it to Rails.
  test('a turn whose send fails is held with Retry, and Retry delivers it', async ({ page, request }) => {
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 1, prefix: 'Before voice mode', resident_count: 1 },
      })
    ).json();
    const { signed_id: recording } = await (await request.post('/test/e2e/audio_blob')).json();
    await page.route('**/voice_mode_session', (route) =>
      route.fulfill({ json: { client_secret: 'ek_e2e', socket_url: 'wss://transcriber.e2e.invalid/realtime' } })
    );
    let item = 0;
    await page.routeWebSocket('wss://transcriber.e2e.invalid/**', (ws) => {
      ws.onMessage((raw) => {
        const event = JSON.parse(String(raw));
        if (event.type !== 'input_audio_buffer.commit') return;
        const id = `item_${++item}`;
        ws.send(JSON.stringify({ type: 'input_audio_buffer.committed', item_id: id }));
        ws.send(
          JSON.stringify({
            type: 'conversation.item.input_audio_transcription.completed',
            item_id: id,
            transcript: 'rough words',
          })
        );
      });
    });
    await page.route('**/chats/*/transcription', (route) => {
      if (route.request().method() !== 'POST') return route.fallback();
      return route.fulfill({ json: { text: 'Five, six, seven, eight', audio_signed_id: recording } });
    });
    // The first send dies on the way, as it does with the screen off.
    let failed = 0;
    await page.route('**/chats/*/messages', (route) => {
      if (route.request().method() !== 'POST' || failed > 0) return route.fallback();
      failed += 1;
      return route.abort('internetdisconnected');
    });
    await page.addInitScript(() => {
      delete BaseAudioContext.prototype.audioWorklet;
    });

    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);
    await page.getByTestId('voice-mode-button').click();
    const held = page.getByTestId('voice-mode-held-turn');
    await expect(held).toContainText('Five, six, seven, eight', { timeout: 20_000 });
    await expect(page.getByTestId('voice-mode-held-reason')).toContainText('Not sent');
    await page.getByRole('button', { name: 'Mute' }).click();

    const sent = page.waitForResponse(
      (response) =>
        response.request().method() === 'POST' && /\/chats\/[^/]+\/messages$/.test(new URL(response.url()).pathname),
      { timeout: 20_000 }
    );
    await page.getByRole('button', { name: 'Retry' }).click();
    const response = await sent;
    expect(response.status(), await response.text()).toBe(201);
    await expect(page.getByTestId('voice-mode-held')).toHaveCount(0);
    await expect(page.getByText('Five, six, seven, eight').first()).toBeVisible({ timeout: 10_000 });
  });
});
