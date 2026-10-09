import { test, expect } from '@playwright/experimental-ct-svelte';
import RecordingPage from '../../app/frontend/pages/field/recordings/show.svelte';
import FieldPage from '../../app/frontend/pages/field/index.svelte';
import VoicesPage from '../../app/frontend/pages/field/voices.svelte';

// Recordings in the Field (spec §7). Names here are made up.
const account = { id: 'acct1', name: 'Wren House' };

const words = [
  { s: 0, e: 400, t: 'Morning', k: 'w', spk: 'speaker_0' },
  { s: 400, e: 400, t: ' ', k: 's', spk: 'speaker_0' },
  { s: 450, e: 900, t: 'everyone.', k: 'w', spk: 'speaker_0' },
  { s: 3000, e: 3500, t: 'Shall', k: 'w', spk: 'speaker_1' },
  { s: 3500, e: 3500, t: ' ', k: 's', spk: 'speaker_1' },
  { s: 3550, e: 3900, t: 'we', k: 'w', spk: 'speaker_1' },
  { s: 3900, e: 3900, t: ' ', k: 's', spk: 'speaker_1' },
  { s: 3950, e: 4400, t: 'start', k: 'w', spk: 'speaker_1' },
  { s: 4400, e: 4400, t: ' ', k: 's', spk: 'speaker_1' },
  { s: 4450, e: 5000, t: 'with', k: 'w', spk: 'speaker_1' },
  { s: 5000, e: 5000, t: ' ', k: 's', spk: 'speaker_1' },
  { s: 5050, e: 5600, t: 'the', k: 'w', spk: 'speaker_1' },
  { s: 5600, e: 5600, t: ' ', k: 's', spk: 'speaker_1' },
  { s: 5650, e: 6200, t: 'venue?', k: 'w', spk: 'speaker_1' },
  { s: 6400, e: 7000, t: '(laughter)', k: 'a', spk: 'speaker_0' },
];

const recording = {
  key: 'recording-r1',
  kind: 'recording',
  id: 'r1',
  title: 'Board call with Priya and Tomás',
  note: 'The venue question again.',
  status: 'ready',
  failure_reason: null,
  duration_ms: 3_725_000,
  expected_speakers: 3,
  filename: 'board-call.m4a',
  byte_size: 48_000_000,
  uploader_name: 'Sam',
  uploader_kind: 'human',
  speaker_names: ['Sam', 'Speaker 2'],
  dispatched: true,
  retryable: false,
  show_url: '/accounts/acct1/field/recordings/r1',
  created_at: '2026-10-08T07:00:00Z',
  audio_url: '/rails/active_storage/blobs/x/board-call.m4a',
  words,
  language_code: 'eng',
  ready_at: '2026-10-08T07:04:00Z',
};

const speakers = [
  {
    id: 's1',
    label: 'speaker_0',
    position: 0,
    default_name: 'Speaker 1',
    name: 'Sam',
    named: true,
    voice_id: 'v1',
    naming_source: 'human',
    talk_ms: 1_200_000,
    clip_start_ms: 0,
    clip_end_ms: 900,
  },
  {
    id: 's2',
    label: 'speaker_1',
    position: 1,
    default_name: 'Speaker 2',
    name: 'Speaker 2',
    named: false,
    voice_id: null,
    naming_source: null,
    talk_ms: 2_100_000,
    clip_start_ms: 3000,
    clip_end_ms: 6200,
    suggestion: {
      name: 'Priya',
      quote: 'Shall we start with the venue?',
      quote_ms: 3000,
      label: "Suggested from what's said",
    },
  },
];

test('the transcript page shows names, unnamed speakers and turns', async ({ mount, page }) => {
  const component = await mount(RecordingPage, {
    props: {
      recording,
      speakers,
      voices: [
        { id: 'v1', name: 'Sam', member: true },
        { id: 'v2', name: 'Priya', member: false },
      ],
      members_without_voice: [],
      my_voice_id: 'v1',
      show_you_hint: false,
      account,
    },
  });

  await expect(component).toContainText('Board call with Priya and Tomás');
  await expect(component).toContainText('Speaker 2');
  await expect(component).toContainText('Shall we start with the venue?');
  await expect(page.getByTestId('speaker-suggestion')).toContainText('Priya?');
  await expect(page.getByTestId('speaker-suggestion')).toContainText("Suggested from what's said");
  await expect(component).not.toContainText('thinks');
  await expect(component).not.toContainText('voice print');
  await page.screenshot({ path: 'tmp/field-recording-show.png', fullPage: true });
});

test('a transcript brought with its audio shows turns, times only where given, and no talk time or clips', async ({
  mount,
  page,
}) => {
  const supplied = {
    ...recording,
    title: 'Evening with Anna',
    transcript_source: 'supplied',
    recorded_at: '2026-10-04T18:45:00Z',
    source_path: 'media/recordings/transcripts/2026-10-04_2045_anna.md',
    words: [],
    turns: [
      { spk: null, s: null, t: 'Source: ~/dev/pa/media/audio/2026-10-04_2045_anna.mp3 (TileRec)' },
      { spk: 'Daniel', s: 0, t: '[cutlery clinking]' },
      { spk: 'Anna', s: 21000, t: 'How am I feeling?\nWell, I enjoyed my day off.' },
      { spk: 'Daniel', s: null, t: 'Mm-hmm.' },
    ],
  };
  const suppliedSpeakers = [
    { id: 's1', label: 'Daniel', position: 0, default_name: 'Daniel', name: 'Daniel', named: false, talk_ms: null },
    { id: 's2', label: 'Anna', position: 1, default_name: 'Anna', name: 'Anna', named: false, talk_ms: null },
  ];
  const component = await mount(RecordingPage, {
    props: {
      recording: supplied,
      speakers: suppliedSpeakers,
      voices: [],
      members_without_voice: [],
      suggestions_enabled: true,
      recognition_enabled: true,
      account,
    },
  });

  await expect(component).toContainText('Transcript brought with it');
  await expect(page.getByTestId('recording-source')).toContainText('2026-10-04_2045_anna.md');
  await expect(page.getByText('How am I feeling?')).toHaveCSS('white-space', 'pre-line');
  await expect(component).toContainText('Unattributed');
  await expect(component).toContainText('00:21');
  await expect(page.getByTestId('speaker-card')).toHaveCount(2);
  await expect(component).not.toContainText('of talk');
  await expect(component).not.toContainText('Hear');
  await expect(page.getByTestId('suggestions-disclosure')).toHaveCount(0);
  await page.screenshot({ path: 'tmp/field-recording-supplied.png', fullPage: true });
});

test('the "is one of these you?" hint shows when asked for', async ({ mount, page }) => {
  const component = await mount(RecordingPage, {
    props: {
      recording,
      speakers,
      voices: [],
      members_without_voice: [],
      my_voice_id: null,
      show_you_hint: true,
      account,
    },
  });
  await expect(component).toContainText('Is one of these you?');
  await page.screenshot({ path: 'tmp/field-recording-hint.png', fullPage: true });
});

const fieldProps = (recordings) => ({
  files: [],
  notes: [],
  recordings,
  recording_allowance: { limit_ms: 72_000_000, used_ms: 12_000_000, pending_ms: 3_600_000, window_days: 7 },
  max_recording_bytes: 2 * 1024 ** 3,
  max_recording_label: '2 GB',
  tab: 'recordings',
  selected: null,
  account_name: 'Wren House',
  account,
});

test('the Recordings tab lists recordings in plain words, with the allowance gauge', async ({ mount, page }) => {
  const component = await mount(FieldPage, {
    props: {
      files: [],
      notes: [],
      recordings: [
        recording,
        {
          ...recording,
          key: 'recording-r2',
          id: 'r2',
          title: 'Tuesday standup',
          status: 'transcribing',
          speaker_names: [],
        },
        {
          ...recording,
          key: 'recording-r3',
          id: 'r3',
          title: 'The long one',
          status: 'rejected',
          speaker_names: [],
          failure_reason:
            'This recording is 4 h 10 m. You have 3 h 20 m left this week. No estimate yet: other recordings are still transcribing.',
          retryable: true,
          dispatched: false,
        },
      ],
      recording_allowance: { limit_ms: 72_000_000, used_ms: 12_000_000, pending_ms: 3_600_000, window_days: 7 },
      max_recording_bytes: 2 * 1024 ** 3,
      max_recording_label: '2 GB',
      tab: 'recordings',
      selected: null,
      account_name: 'Wren House',
      account,
    },
  });

  await expect(component).toContainText('Recordings');
  await expect(component).toContainText('Transcribing');
  await expect(component).toContainText('No estimate yet');
  await expect(component).toContainText('20 h');
  await page.screenshot({ path: 'tmp/field-recordings-tab.png', fullPage: true });
});

// ---------------------------------------------------------------------------
// Bringing a recording in: one cancel/close lifecycle (review of #214).

function deferred() {
  let resolve;
  const promise = new Promise((r) => (resolve = r));
  return { promise, resolve };
}

// Stands in for Active Storage and the recordings endpoint. Each stage can be held open so the
// dialog can be closed while it is in flight; everything that reaches the network is logged.
async function fakeBackend(page) {
  const log = { creates: 0, puts: 0, posts: [], aborted: [] };
  const holds = {};
  page.on('requestfailed', (request) => log.aborted.push(`${request.method()} ${new URL(request.url()).pathname}`));
  const settle = async (route, respond) => {
    try {
      await respond();
    } catch {
      // The page aborted the request while it was held.
    }
  };
  await page.route('**/accounts/acct1/field/recordings/uploads', async (route) => {
    log.creates += 1;
    const n = log.creates;
    await holds.create?.promise;
    await settle(route, () =>
      route.fulfill({
        json: {
          id: n,
          key: `k${n}`,
          filename: 'call.m4a',
          content_type: 'audio/mp4',
          byte_size: 10,
          checksum: 'x',
          signed_id: `signed-${n}`,
          direct_upload: { url: `/test-storage/${n}`, headers: {} },
        },
      })
    );
  });
  await page.route('**/test-storage/*', async (route) => {
    log.puts += 1;
    await holds.put?.promise;
    await settle(route, () => route.fulfill({ status: 204, body: '' }));
  });
  await page.route('**/accounts/acct1/field/recordings', async (route) => {
    log.posts.push(route.request().postDataJSON());
    await holds.post?.promise;
    await settle(route, () => route.fulfill({ json: {} }));
  });
  return { log, holds };
}

// The checksum is read with FileReader before anything is sent. Holding it lets a test close the
// dialog during "Getting the file ready…" and then let the checksum finish afterwards.
async function holdChecksum(page) {
  await page.evaluate(() => {
    const real = FileReader.prototype.readAsArrayBuffer;
    window.__held = [];
    window.__holding = true;
    FileReader.prototype.readAsArrayBuffer = function (blob) {
      if (window.__holding) window.__held.push(() => real.call(this, blob));
      else real.call(this, blob);
    };
  });
}
const releaseChecksum = (page) =>
  page.evaluate(() => {
    window.__holding = false;
    window.__held.splice(0).forEach((read) => read());
  });

const dialog = (page) => page.locator('[data-slot="dialog-content"]');
const audioFile = { name: 'call.m4a', mimeType: 'audio/mp4', buffer: Buffer.from('not really audio') };

async function startUpload(page, title) {
  await page.getByTestId('field-add-recording').click();
  await expect(dialog(page)).toBeVisible();
  await dialog(page).locator('#recording-file').setInputFiles(audioFile);
  await dialog(page).locator('#recording-title').fill(title);
  await dialog(page).getByRole('button', { name: 'Bring it in' }).click();
}

const closeBy = {
  'the Cancel button': (page) => dialog(page).getByTestId('recording-upload-close').click(),
  'the X': (page) => dialog(page).getByRole('button', { name: 'Close', exact: true }).click(),
  Escape: (page) => page.keyboard.press('Escape'),
  'the backdrop': (page) => page.mouse.click(8, 8),
};

// After an abandoned attempt the dialog must come back clean and a new upload must go all the way.
async function reopenAndComplete(page, log, expectedSignedId) {
  await page.getByTestId('field-add-recording').click();
  await expect(dialog(page)).toBeVisible();
  await expect(dialog(page).getByTestId('recording-progress')).toHaveCount(0);
  await expect(dialog(page).locator('#recording-file')).toBeEnabled();
  await expect(dialog(page).locator('#recording-title')).toHaveValue('');
  await expect(dialog(page).getByRole('button', { name: 'Bring it in' })).toBeDisabled();
  await dialog(page).locator('#recording-file').setInputFiles(audioFile);
  await dialog(page).locator('#recording-title').fill('Second try');
  await dialog(page).getByRole('button', { name: 'Bring it in' }).click();
  await expect(dialog(page)).toHaveCount(0);
  expect(log.posts).toHaveLength(1);
  expect(log.posts[0].field_recording).toMatchObject({ upload_id: expectedSignedId, title: 'Second try' });
}

test('cancelling while the file is being prepared sends nothing, even when preparing finishes', async ({
  mount,
  page,
}) => {
  await mount(FieldPage, { props: fieldProps([]) });
  const { log } = await fakeBackend(page);
  await holdChecksum(page);
  await startUpload(page, 'Abandoned while preparing');
  await expect(dialog(page)).toContainText('Getting the file ready…');
  await page.screenshot({ path: 'tmp/field-recording-upload-preparing.png' });

  await closeBy['the Cancel button'](page);
  await expect(dialog(page)).toHaveCount(0);
  await releaseChecksum(page);
  await page.waitForTimeout(500);
  expect(log.creates).toBe(0);
  expect(log.puts).toBe(0);
  expect(log.posts).toHaveLength(0);

  await reopenAndComplete(page, log, 'signed-1');
});

test('cancelling while the blob is being created aborts it and nothing follows', async ({ mount, page }) => {
  await mount(FieldPage, { props: fieldProps([]) });
  const { log, holds } = await fakeBackend(page);
  holds.create = deferred();
  await startUpload(page, 'Abandoned while creating the blob');
  await expect.poll(() => log.creates).toBe(1);

  await closeBy['the Cancel button'](page);
  await expect(dialog(page)).toHaveCount(0);
  await expect.poll(() => log.aborted).toContain('POST /accounts/acct1/field/recordings/uploads');
  holds.create.resolve();
  await page.waitForTimeout(500);
  expect(log.puts).toBe(0);
  expect(log.posts).toHaveLength(0);

  await reopenAndComplete(page, log, 'signed-2');
});

for (const [route, close] of Object.entries(closeBy)) {
  test(`closing by ${route} during the upload aborts it, and a new upload then goes through`, async ({
    mount,
    page,
  }) => {
    await mount(FieldPage, { props: fieldProps([]) });
    const { log, holds } = await fakeBackend(page);
    holds.put = deferred();
    await startUpload(page, `Abandoned by ${route}`);
    await expect.poll(() => log.puts).toBe(1);

    await close(page);
    await expect(dialog(page)).toHaveCount(0);
    await expect.poll(() => log.aborted).toContain('PUT /test-storage/1');
    holds.put.resolve();
    await page.waitForTimeout(500);
    expect(log.posts).toHaveLength(0);

    holds.put = null;
    await reopenAndComplete(page, log, 'signed-2');
  });
}

test('once the recording is being brought in, closing only closes: it says Close and the POST still lands', async ({
  mount,
  page,
}) => {
  await mount(FieldPage, { props: fieldProps([]) });
  const { log, holds } = await fakeBackend(page);
  holds.post = deferred();
  await startUpload(page, 'Too late to stop');
  await expect.poll(() => log.posts.length).toBe(1);
  await expect(dialog(page)).toContainText('Uploaded. Bringing it in…');
  await expect(dialog(page).getByTestId('recording-upload-close')).toHaveText('Close');
  await page.screenshot({ path: 'tmp/field-recording-upload-posting.png' });

  await closeBy['the Cancel button'](page);
  await expect(dialog(page)).toHaveCount(0);
  // Reopening while it is still out shows it still going, not a fresh form.
  await page.getByTestId('field-add-recording').click();
  await expect(dialog(page)).toContainText('Uploaded. Bringing it in…');
  await page.keyboard.press('Escape');
  holds.post.resolve();
  await page.waitForTimeout(300);
  expect(log.posts).toHaveLength(1);
  expect(log.posts[0].field_recording).toMatchObject({ upload_id: 'signed-1', title: 'Too late to stop' });

  await page.getByTestId('field-add-recording').click();
  await expect(dialog(page).getByTestId('recording-progress')).toHaveCount(0);
  await expect(dialog(page).getByRole('button', { name: 'Cancel' })).toBeVisible();
  await expect(dialog(page).locator('#recording-title')).toHaveValue('');
});

// ---------------------------------------------------------------------------
// "Hear" plays one speaker's clip and stops at its end (review of #214).

function silentWav(seconds, rate = 8000) {
  const n = seconds * rate;
  const buf = Buffer.alloc(44 + n);
  buf.write('RIFF', 0);
  buf.writeUInt32LE(36 + n, 4);
  buf.write('WAVE', 8);
  buf.write('fmt ', 12);
  buf.writeUInt32LE(16, 16);
  buf.writeUInt16LE(1, 20);
  buf.writeUInt16LE(1, 22);
  buf.writeUInt32LE(rate, 24);
  buf.writeUInt32LE(rate, 28);
  buf.writeUInt16LE(1, 32);
  buf.writeUInt16LE(8, 34);
  buf.write('data', 36);
  buf.writeUInt32LE(n, 40);
  buf.fill(128, 44);
  return buf;
}

const playable = { ...recording, audio_url: `data:audio/wav;base64,${silentWav(12).toString('base64')}` };

async function mountPlayer(mount, page) {
  const component = await mount(RecordingPage, {
    props: {
      recording: playable,
      speakers,
      voices: [],
      members_without_voice: [],
      my_voice_id: null,
      show_you_hint: false,
      account,
    },
  });
  const audio = page.getByTestId('recording-audio');
  await expect.poll(() => audio.evaluate((el) => el.readyState)).toBeGreaterThanOrEqual(1);
  await audio.evaluate((el) => {
    el.playbackRate = 2;
    window.__seeks = 0;
    el.addEventListener('seeking', () => (window.__seeks += 1));
  });
  return { component, audio };
}
const state = (audio) => audio.evaluate((el) => ({ t: el.currentTime, paused: el.paused, ended: el.ended }));
const hearSpeaker2 = (page) => page.getByRole('button', { name: 'Hear a few seconds of this voice' }).nth(1);

test("Hear stops at the clip's end, through the seeking event its own jump fires", async ({ mount, page }) => {
  const { audio } = await mountPlayer(mount, page);
  await hearSpeaker2(page).click();
  // The clip's own jump to 3.0 s fired a real `seeking` event...
  await expect.poll(() => page.evaluate(() => window.__seeks)).toBeGreaterThanOrEqual(1);
  // ...and playback still stops once it crosses the clip's end at 6.2 s.
  await expect.poll(() => state(audio).then((s) => s.paused), { timeout: 10_000 }).toBe(true);
  const stopped = await state(audio);
  expect(stopped.t).toBeGreaterThanOrEqual(6.2);
  expect(stopped.t).toBeLessThan(7.5);
  expect(stopped.ended).toBe(false);
  await page.screenshot({ path: 'tmp/field-recording-clip-stopped.png', fullPage: true });
});

test('a seek by the listener ends the clip, so playback carries on past its end', async ({ mount, page }) => {
  const { audio } = await mountPlayer(mount, page);
  await hearSpeaker2(page).click();
  await expect.poll(() => state(audio).then((s) => s.t)).toBeGreaterThan(3.2);
  await audio.evaluate((el) => (el.currentTime = 4.5));
  await expect.poll(() => state(audio).then((s) => s.t), { timeout: 10_000 }).toBeGreaterThan(7);
  expect((await state(audio)).paused).toBe(false);
});

test('clicking a turn while a clip plays ends the clip too', async ({ mount, page }) => {
  const { audio } = await mountPlayer(mount, page);
  await hearSpeaker2(page).click();
  await expect.poll(() => state(audio).then((s) => s.t)).toBeGreaterThan(3.2);
  await page.getByTestId('transcript').getByText('venue?').click();
  await expect.poll(() => state(audio).then((s) => s.t), { timeout: 10_000 }).toBeGreaterThan(7);
  expect((await state(audio)).paused).toBe(false);
});

// Slice C: recognition and "remember this voice" (spec §9). Behind two gates.

const recognitionSpeakers = [
  {
    ...speakers[0],
    can_remember: false,
    remembered: true,
    remembering: false,
    recognition: null,
    pending_enrolment: null,
  },
  {
    ...speakers[1],
    suggestion: null,
    recognition: {
      name: 'Tomás',
      confidence: 82,
      token: { voice_id: 'v9', print_generation: 3, decision_generation: 0 },
    },
    can_remember: false,
    remembered: false,
    remembering: false,
    pending_enrolment: null,
  },
  {
    id: 's3',
    label: 'speaker_2',
    position: 2,
    default_name: 'Speaker 3',
    name: 'Priya',
    named: true,
    voice_id: 'v2',
    naming_source: 'human',
    talk_ms: 400_000,
    clip_start_ms: null,
    clip_end_ms: null,
    recognition: null,
    can_remember: true,
    remembered: false,
    remembering: false,
    pending_enrolment: null,
  },
  {
    id: 's4',
    label: 'speaker_3',
    position: 3,
    default_name: 'Speaker 4',
    name: 'Ana',
    named: true,
    voice_id: 'v3',
    naming_source: 'human',
    talk_ms: 25_000,
    clip_start_ms: null,
    clip_end_ms: null,
    recognition: null,
    can_remember: true,
    remembered: false,
    remembering: false,
    pending_enrolment: { id: 'e1', sample_ms: 14_200, sample_url: '/rails/active_storage/blobs/y/sample.wav' },
  },
];

const recognitionProps = (enabled) => ({
  recording,
  speakers: recognitionSpeakers,
  voices: [
    { id: 'v1', name: 'Sam', member: true },
    { id: 'v2', name: 'Priya', member: false },
    { id: 'v3', name: 'Ana', member: false },
  ],
  members_without_voice: [],
  my_voice_id: 'v1',
  show_you_hint: false,
  recognition_enabled: enabled,
  account,
});

test('with recognition on, speakers get the recognition chip, the remember offer and the preview', async ({
  mount,
  page,
}) => {
  const component = await mount(RecordingPage, { props: recognitionProps(true) });

  const chip = page.getByTestId('speaker-recognition');
  await expect(chip).toContainText('Tomás?');
  await expect(chip).toContainText('sounds like the Tomás this Field remembers');
  await expect(chip).toContainText('(82)');
  await expect(chip.getByRole('button', { name: "That's Tomás" })).toBeVisible();

  await expect(page.getByTestId('remember-voice')).toHaveText("Remember Priya's voice…");
  await expect(page.getByTestId('voice-preview')).toContainText('This is what will be remembered as Ana.');
  await expect(page.getByTestId('voice-preview')).toContainText('14 s of clear speech');
  await expect(page.getByTestId('voice-preview').getByRole('button', { name: 'Use it' })).toBeVisible();
  await expect(component).toContainText('This Field remembers your voice');
  await expect(page.getByRole('link', { name: 'Voices this Field knows' })).toBeVisible();
  await expect(component).not.toContainText('thinks');
  await expect(component).not.toContainText('voice print');
  await page.screenshot({ path: 'tmp/field-recognition-show.png', fullPage: true });

  await page.getByTestId('remember-voice').click();
  const panel = page.getByTestId('remember-voice-panel');
  await expect(panel).toContainText(
    "Remember Priya's voice so this Field can suggest them in later recordings. Only tick this if Priya has agreed."
  );
  await expect(page.getByTestId('remember-voice-consent')).not.toBeChecked();
  await expect(page.getByTestId('remember-voice-continue')).toBeDisabled();
  await panel.getByText('What this means').click();
  await expect(page.getByTestId('voice-meaning')).toContainText('voice print');
  await expect(page.getByTestId('voice-meaning')).toContainText('The Voices page says how long');
  await page.getByTestId('remember-voice-consent').check();
  await expect(page.getByTestId('remember-voice-continue')).toBeEnabled();
  await page.screenshot({ path: 'tmp/field-recognition-remember.png', fullPage: true });

  // Closing and reopening starts unticked again.
  await page.getByRole('button', { name: 'Cancel' }).click();
  await page.getByTestId('remember-voice').click();
  await expect(page.getByTestId('remember-voice-consent')).not.toBeChecked();
});

test('with recognition off, the transcript page has no recognition, remember offer or preview', async ({
  mount,
  page,
}) => {
  const component = await mount(RecordingPage, { props: recognitionProps(false) });
  await expect(component).toContainText('Priya');
  await expect(page.getByTestId('speaker-recognition')).toHaveCount(0);
  await expect(page.getByTestId('remember-voice')).toHaveCount(0);
  await expect(page.getByTestId('voice-preview')).toHaveCount(0);
  await expect(page.getByTestId('voice-status')).toHaveCount(0);
  await expect(page.getByRole('link', { name: 'Voices this Field knows' })).toBeVisible();
  await page.screenshot({ path: 'tmp/field-recognition-off.png', fullPage: true });
});

const voices = [
  {
    id: 'v1',
    name: 'Sam',
    member: true,
    used_in: 4,
    remembered: true,
    sample_seconds: 22,
    remembered_at: '2026-10-08T08:00:00Z',
    remembered_by: 'Sam Rivers',
  },
  {
    id: 'v2',
    name: 'Priya',
    member: false,
    used_in: 1,
    remembered: false,
    sample_seconds: null,
    remembered_at: null,
    remembered_by: null,
  },
];

test('the Voices page, house gate on: the switch, Forget and the backup days', async ({ mount, page }) => {
  const component = await mount(VoicesPage, {
    props: {
      voices,
      recognise_voices: false,
      house_recognition: true,
      can_change_setting: true,
      backup_retention_days: 30,
      account,
    },
  });
  await expect(component).toContainText('Voices this Field knows');
  await expect(page.getByTestId('voices-switch')).toBeVisible();
  await expect(page.getByTestId('voices-switch')).toBeEnabled();
  await expect(component).toContainText("Suggest who's speaking from voices this Field remembers");
  await expect(component).toContainText('Remembered voices are kept but not used while this is off.');
  await expect(page.getByTestId('voices-forget-all')).toBeVisible();
  await expect(page.getByTestId('voice-forget')).toHaveCount(1);
  await expect(page.getByTestId('voice-row').first()).toContainText('Voice remembered (22 s sample, by Sam Rivers');
  await expect(page.getByTestId('voice-row').nth(1)).toContainText('Name only');
  await expect(page.getByTestId('voice-meaning-backups')).toContainText('after 30 days');
  await expect(component).not.toContainText('thinks');
  await page.screenshot({ path: 'tmp/field-voices-on.png', fullPage: true });
});

test('the Voices page, house gate off: no switch, but a remembered voice can still be forgotten', async ({
  mount,
  page,
}) => {
  const component = await mount(VoicesPage, {
    props: {
      voices,
      recognise_voices: true,
      house_recognition: false,
      can_change_setting: true,
      backup_retention_days: null,
      account,
    },
  });
  await expect(component).toContainText("Voice recognition isn't available in this house yet.");
  await expect(page.getByTestId('voices-switch')).toHaveCount(0);
  await expect(page.getByTestId('voice-forget')).toHaveCount(1);
  await expect(page.getByTestId('voices-forget-all')).toBeVisible();
  await expect(page.getByTestId('voice-meaning-backups')).toHaveCount(0);
  await page.screenshot({ path: 'tmp/field-voices-house-off.png', fullPage: true });
});
