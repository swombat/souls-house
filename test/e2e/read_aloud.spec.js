import { expect, test } from '@playwright/test';

// "Read replies aloud" (eVvVEe): the header's speaker reads each reply that
// lands after it was switched on, with no microphone and no voice mode panel.
// Daniel's case: outdoors, voice mode's speech detector kept "hearing" street
// noise and held every reply. This checks the real wiring (Rails broadcast,
// ActionCable, the Inertia reload, the header toggle, the picker and the
// player) with the ElevenLabs engine, whose audio the player asks the server
// for; that request is stubbed, so nothing leaves the machine.

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

test.describe('read replies aloud', () => {
  let setup;

  test.beforeEach(async ({ request }) => {
    const response = await request.post('/test/e2e/setup', {
      data: { run_id: `read-aloud-${Date.now()}-${Math.random().toString(36).slice(2)}` },
    });
    expect(response.ok()).toBe(true);
    setup = await response.json();
  });

  test.afterEach(async ({ request }) => {
    if (setup) await request.post('/test/e2e/cleanup', { data: { run_id: setup.run_id } });
  });

  test('switched on, a reply that lands is read once without voice mode; history is not', async ({ page, request }) => {
    const voice = await request.post('/test/e2e/voice_mode_fixture', {
      data: { account_id: setup.account_id, speech_engine: 'elevenlabs' },
    });
    expect(voice.ok()).toBe(true);
    const fixture = await (
      await request.post('/test/e2e/conversation_fixture', {
        data: { account_id: setup.account_id, count: 2, prefix: 'Before reading aloud', resident_count: 1 },
      })
    ).json();

    const speech = [];
    await page.route('**/messages/*/speech', (route) => {
      speech.push(new URL(route.request().url()).pathname);
      return route.fulfill({ status: 200, contentType: 'audio/wav', body: silentWav() });
    });
    // Count the element's play() calls, so the test sees the player start.
    await page.addInitScript(() => {
      window.__plays = [];
      const play = HTMLMediaElement.prototype.play;
      HTMLMediaElement.prototype.play = function () {
        window.__plays.push(this.src);
        return play.call(this);
      };
    });

    await page.setViewportSize({ width: 360, height: 760 });
    await page.goto('/login');
    await page.getByLabel(/email/i).fill(setup.primary_user.email);
    await page.getByLabel(/password/i).fill(setup.password);
    await page.getByRole('button', { name: /sign in|log in/i }).click();
    await expect(page).not.toHaveURL(/\/login/);
    await page.goto(`/accounts/${setup.account_id}/chats/${fixture.chat_id}`);

    const toggle = page.getByTestId('read-aloud-toggle');
    await expect(toggle).toBeVisible();
    await expect(toggle).toHaveAttribute('data-state', 'off');
    await expect(toggle).toHaveAttribute('aria-pressed', 'false');
    await toggle.click();
    await expect(toggle).toHaveAttribute('data-state', 'on');
    await expect(toggle).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByTestId('voice-mode-panel')).toHaveCount(0);

    const landed = await (
      await request.post('/test/e2e/assistant_message', {
        data: { chat_id: fixture.chat_id, content: 'Landed while reading aloud was on' },
      })
    ).json();

    await expect(page.getByText('Landed while reading aloud was on').first()).toBeVisible({ timeout: 10_000 });
    await expect.poll(() => speech, { timeout: 10_000 }).toContain(`/messages/${landed.message_id}/speech`);
    await expect
      .poll(() => page.evaluate(() => window.__plays.filter((src) => src.includes('/speech')).length), {
        timeout: 10_000,
      })
      .toBe(1);
    // Only the new reply: the two messages already on the page were not asked for.
    expect(speech).toEqual([`/messages/${landed.message_id}/speech`]);

    // A reload of this conversation keeps it on.
    await page.reload();
    await expect(page.getByTestId('read-aloud-toggle')).toHaveAttribute('aria-pressed', 'true');
    await page.getByTestId('read-aloud-toggle').click();
    await expect(page.getByTestId('read-aloud-toggle')).toHaveAttribute('data-state', 'off');
  });
});
