import { test, expect } from '@playwright/experimental-ct-svelte';
import RecordingPage from '../../app/frontend/pages/field/recordings/show.svelte';
import FieldPage from '../../app/frontend/pages/field/index.svelte';
import VoicesPage from '../../app/frontend/pages/field/voices.svelte';
import RecordingViewer from '../../app/frontend/lib/components/field/RecordingViewer.svelte';

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
  transcript_revision: 'rev1',
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

test('an unnamed speaker can be set aside as noise, and an ignored one undone', async ({ mount, page }) => {
  const sent = [];
  await page.route('**/accounts/acct1/field/recordings/r1/speakers/*', async (route) => {
    sent.push({ url: route.request().url(), method: route.request().method(), body: route.request().postDataJSON() });
    await route.fulfill({ json: {} });
  });
  const props = { recording, voices: [], members_without_voice: [], my_voice_id: null, show_you_hint: false, account };
  let component = await mount(RecordingPage, { props: { ...props, speakers } });

  const cards = page.getByTestId('speaker-card');
  await expect(cards.nth(0).getByTestId('speaker-ignore')).toHaveCount(0);
  await cards.nth(1).getByTestId('speaker-ignore').click();
  await expect.poll(() => sent.length).toBe(1);
  expect(sent[0].method).toBe('PATCH');
  expect(sent[0].url).toContain('/speakers/s2');
  expect(sent[0].body).toEqual({ speaker: { ignore: true } });
  await component.unmount();

  const ignored = { ...speakers[1], ignored: true, suggestion: null };
  component = await mount(RecordingPage, { props: { ...props, speakers: [speakers[0], ignored] } });
  const card = page.locator('[data-testid="speaker-card"][data-ignored="true"]');
  await expect(card).toContainText('Ignored as noise');
  await expect(card.getByTestId('speaker-ignore')).toHaveCount(0);
  await expect(card.getByTestId('speaker-chip')).toHaveCount(0);
  await page.screenshot({ path: 'tmp/field-recording-ignored.png', fullPage: true });
  await card.getByTestId('speaker-unignore').click();
  await expect.poll(() => sent.length).toBe(2);
  expect(sent[1].body).toEqual({ speaker: { unignore: true } });
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

test('one voice heard as two speakers shows as one card, with its parts', async ({ mount, page }) => {
  const twice = [
    ...speakers.map(({ suggestion, ...speaker }) => speaker),
    {
      id: 's3',
      label: 'speaker_2',
      position: 2,
      default_name: 'Speaker 3',
      name: 'Sam',
      named: true,
      voice_id: 'v1',
      naming_source: 'human',
      talk_ms: 600_000,
      clip_start_ms: 6400,
      clip_end_ms: 7000,
    },
  ];
  const component = await mount(RecordingPage, {
    props: {
      recording: { ...recording, words: [...words, { s: 7100, e: 7600, t: 'Agreed.', k: 'w', spk: 'speaker_2' }] },
      speakers: twice,
      voices: [{ id: 'v1', name: 'Sam' }],
      members_without_voice: [],
      my_voice_id: null,
      account,
    },
  });

  await expect(page.getByTestId('speaker-card')).toHaveCount(2);
  const sam = page.getByTestId('speaker-card').first();
  await expect(sam).toContainText('Sam');
  await expect(sam).toContainText('30 m');
  await sam.getByTestId('speaker-parts-toggle').click();
  await expect(sam.getByTestId('speaker-parts')).toContainText('Speaker 1');
  await expect(sam.getByTestId('speaker-parts')).toContainText('Speaker 3');
  await expect(sam.getByTestId('speaker-part-unlink')).toHaveCount(2);
  await expect(sam.getByTestId('speaker-part-unlink').first()).toHaveText('Not Sam');
  await expect(component).toContainText('(laughter) Agreed.');
  await page.screenshot({ path: 'tmp/field-recording-merged-voice.png', fullPage: true });
});

test('a merged card keeps a voice sample waiting on a part that does not stand for it', async ({ mount, page }) => {
  const part = (id, label, position, extra) => ({
    id,
    label,
    position,
    default_name: `Speaker ${position + 1}`,
    name: 'Sam',
    named: true,
    voice_id: 'v1',
    naming_source: 'human',
    can_remember: true,
    remembered: false,
    remembering: false,
    pending_enrolment: null,
    ...extra,
  });
  await mount(RecordingPage, {
    props: {
      recording,
      speakers: [
        part('s1', 'speaker_0', 0, {
          talk_ms: 60_000,
          pending_enrolment: { id: 'e9', sample_ms: 12_000, sample_url: '/rails/active_storage/blobs/z/sample.wav' },
        }),
        part('s2', 'speaker_1', 1, { talk_ms: 600_000, clip_start_ms: 6400, clip_end_ms: 7000 }),
      ],
      voices: [{ id: 'v1', name: 'Sam' }],
      members_without_voice: [],
      my_voice_id: null,
      recognition_enabled: true,
      account,
    },
  });

  const sam = page.getByTestId('speaker-card');
  await expect(sam).toHaveCount(1);
  const own = sam.getByTestId('speaker-part-enrolment');
  await expect(own).toContainText('From Speaker 1');
  await expect(own.getByTestId('voice-preview')).toContainText('12 s of clear speech');
  await expect(own.getByRole('button', { name: 'Use it' })).toBeVisible();
  await expect(own.getByRole('button', { name: 'Not them' })).toBeVisible();
  await expect(sam.getByTestId('remember-voice')).toHaveCount(1);
});

const fieldProps = (recordings) => ({
  items: recordings,
  field_empty: recordings.length === 0,
  counts: { all: recordings.length, files: 0, notes: 0, recordings: recordings.length },
  pagination: { page: 1, pages: 1, per_page: 50, total: recordings.length },
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
      items: [
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
      counts: { all: 3, files: 0, notes: 0, recordings: 3 },
      pagination: { page: 1, pages: 1, per_page: 50, total: 3 },
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

test('listening to a line while a clip plays ends the clip too', async ({ mount, page }) => {
  const { audio } = await mountPlayer(mount, page);
  await hearSpeaker2(page).click();
  await expect.poll(() => state(audio).then((s) => s.t)).toBeGreaterThan(3.2);
  await page.getByRole('button', { name: 'Listen to this line' }).nth(1).click();
  await expect.poll(() => state(audio).then((s) => s.t), { timeout: 10_000 }).toBeGreaterThan(7);
  expect((await state(audio)).paused).toBe(false);
});

// Correcting a line by hand: with a mouse, clicking a line edits it in place
// and a speaker button beside it plays it; on touch, tapping offers Edit and
// Listen, and pressing and holding edits straight away.

async function captureLinePatches(page) {
  const sent = [];
  await page.route('**/accounts/acct1/field/recordings/r1/line', async (route) => {
    sent.push(route.request().postDataJSON());
    await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });
  return sent;
}

test('with a mouse, clicking a line edits it in place and Enter saves it', async ({ mount, page }) => {
  const sent = await captureLinePatches(page);
  await mountPlayer(mount, page);
  const line = page.getByTestId('transcript-line').nth(1);
  await line.hover();
  await expect(page.getByRole('button', { name: 'Listen to this line' }).nth(1)).toBeVisible();
  await line.click();

  const editor = page.getByTestId('line-editor');
  await expect(editor).toHaveValue('Shall we start with the venue?');
  await page.screenshot({ path: 'tmp/field-line-edit-desktop.png' });
  await editor.fill('Shall we start with the venue, Dan?');
  await editor.press('Enter');

  await expect.poll(() => sent.length).toBe(1);
  expect(sent[0]).toEqual({
    line: {
      first: 2,
      last: 7,
      text: 'Shall we start with the venue, Dan?',
      was: 'Shall we start with the venue?',
      revision: 'rev1',
    },
  });
  await expect(editor).toHaveCount(0);
});

test('Escape leaves a line as it was, and an unchanged line sends nothing', async ({ mount, page }) => {
  const sent = await captureLinePatches(page);
  await mountPlayer(mount, page);
  await page.getByTestId('transcript-line').first().click();
  await page.getByTestId('line-editor').fill('Mourning everyone.');
  await page.getByTestId('line-editor').press('Escape');
  await expect(page.getByTestId('line-editor')).toHaveCount(0);
  await page.getByTestId('transcript-line').first().click();
  await page.getByTestId('line-save').click();
  await expect(page.getByTestId('line-editor')).toHaveCount(0);
  expect(sent).toEqual([]);
});

test('while a save is in flight, the editor stays on that line: no switching, no cancel', async ({ mount, page }) => {
  let release;
  const held = new Promise((resolve) => (release = resolve));
  await page.route('**/accounts/acct1/field/recordings/r1/line', async (route) => {
    await held;
    await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });
  await mountPlayer(mount, page);
  const lines = page.getByTestId('transcript-line');
  await lines.nth(1).click();
  await page.getByTestId('line-editor').fill('Shall we start with the venue, Dan?');
  await page.getByTestId('line-editor').press('Enter');
  await expect(page.getByTestId('line-save')).toHaveText('Saving…');

  await lines.first().click();
  await page.getByTestId('line-editor').press('Escape');
  await expect(page.getByTestId('line-editor')).toHaveValue('Shall we start with the venue, Dan?');

  release();
  await expect(page.getByTestId('line-editor')).toHaveCount(0);
  await lines.first().click();
  await expect(page.getByTestId('line-editor')).toHaveValue('Morning everyone.');
});

test('a refused save keeps the text and says why', async ({ mount, page }) => {
  await page.route('**/accounts/acct1/field/recordings/r1/line', (route) =>
    route.fulfill({
      status: 422,
      contentType: 'application/json',
      body: JSON.stringify({ props: { errors: { line: 'The transcript changed while you were editing.' } } }),
    })
  );
  await mountPlayer(mount, page);
  await page.getByTestId('transcript-line').nth(1).click();
  await page.getByTestId('line-editor').fill('Shall we start with the venue, Dan?');
  await page.getByTestId('line-save').click();
  await expect(page.getByTestId('line-error')).toHaveText('The transcript changed while you were editing.');
  await expect(page.getByTestId('line-editor')).toHaveValue('Shall we start with the venue, Dan?');
});

test('a failed request keeps the text too', async ({ mount, page }) => {
  await page.route('**/accounts/acct1/field/recordings/r1/line', (route) => route.fulfill({ status: 500, body: '' }));
  await mountPlayer(mount, page);
  await page.getByTestId('transcript-line').nth(1).click();
  await page.getByTestId('line-editor').fill('Shall we start with the venue, Dan?');
  await page.getByTestId('line-editor').press('Enter');
  await expect(page.getByTestId('line-error')).toBeVisible();
  await expect(page.getByTestId('line-editor')).toHaveValue('Shall we start with the venue, Dan?');
});

// Giving a line to the right person: the speaker's name over a line opens
// "Who said this?" with the other people in the recording and "Someone new".

async function captureSpeakerPatches(page, reply = null) {
  const sent = [];
  await page.route('**/accounts/acct1/field/recordings/r1/line_speaker', async (route) => {
    sent.push(route.request().postDataJSON());
    await route.fulfill(reply || { status: 200, contentType: 'application/json', body: '{}' });
  });
  return sent;
}

test("with a mouse, a line's speaker shows a caret on hover and gives the line to someone else", async ({
  mount,
  page,
}) => {
  const sent = await captureSpeakerPatches(page);
  await mountPlayer(mount, page);
  const speaker = page.getByTestId('line-speaker').nth(1);
  await expect(speaker).toHaveText('Speaker 2');
  await speaker.hover();
  await speaker.click();

  const menu = page.getByTestId('line-speaker-menu');
  await expect(menu).toBeVisible();
  await expect(menu.getByRole('menuitem')).toHaveText(['Sam', 'Someone new']);
  await expect(page.getByTestId('line-editor')).toHaveCount(0);
  await page.screenshot({ path: 'tmp/field-line-speaker-desktop.png' });

  await menu.getByRole('menuitem', { name: 'Sam' }).click();
  await expect.poll(() => sent.length).toBe(1);
  expect(sent[0]).toEqual({
    line: { first: 2, last: 7, was: 'Shall we start with the venue?', revision: 'rev1', speaker: 's1' },
  });
  await expect(menu).toHaveCount(0);
});

test('Escape or a click elsewhere closes the speaker menu and sends nothing', async ({ mount, page }) => {
  const sent = await captureSpeakerPatches(page);
  await mountPlayer(mount, page);
  await page.getByTestId('line-speaker').first().click();
  await expect(page.getByTestId('line-speaker-menu')).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByTestId('line-speaker-menu')).toHaveCount(0);
  await page.getByTestId('line-speaker').first().click();
  await page.getByRole('heading', { name: recording.title }).click();
  await expect(page.getByTestId('line-speaker-menu')).toHaveCount(0);
  expect(sent).toEqual([]);
});

test("opening another line's speaker menu closes the first", async ({ mount, page }) => {
  await mountPlayer(mount, page);
  // The open menu lies over the lines below it, so go to the line above.
  await page.getByTestId('line-speaker').nth(1).click();
  await page.getByTestId('line-speaker').first().click();
  await expect(page.getByTestId('line-speaker-menu')).toHaveCount(1);
  await expect(page.getByTestId('line-speaker-menu').getByRole('menuitem').first()).toHaveText('Speaker 2');
});

test('a refused move says why', async ({ mount, page }) => {
  await captureSpeakerPatches(page, {
    status: 422,
    contentType: 'application/json',
    body: JSON.stringify({ props: { errors: { line_speaker: 'The transcript changed since the page loaded.' } } }),
  });
  await mountPlayer(mount, page);
  await page.getByTestId('line-speaker').first().click();
  await page.getByTestId('line-speaker-new').click();
  await expect(page.getByTestId('line-speaker-error')).toBeVisible();
});

test.describe('on a phone', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test('tapping a line offers Edit and Listen', async ({ mount, page }) => {
    const sent = await captureLinePatches(page);
    const { audio } = await mountPlayer(mount, page);
    await page.getByTestId('transcript-line').nth(1).tap();

    const menu = page.getByTestId('line-menu');
    await expect(menu).toBeVisible();
    await expect(page.getByTestId('line-editor')).toHaveCount(0);
    await page.screenshot({ path: 'tmp/field-line-menu-mobile.png' });

    await menu.getByRole('button', { name: 'Listen' }).tap();
    await expect(menu).toHaveCount(0);
    await expect.poll(() => state(audio).then((s) => s.t)).toBeGreaterThan(3);

    await page.getByTestId('transcript-line').nth(1).tap();
    await page.getByTestId('line-menu').getByRole('button', { name: 'Edit' }).tap();
    await page.getByTestId('line-editor').fill('Shall we start with the venue, Dan?');
    await page.getByTestId('line-save').tap();
    await expect.poll(() => sent.length).toBe(1);
  });

  test("tapping a line's speaker offers the others and someone new", async ({ mount, page }) => {
    const sent = await captureSpeakerPatches(page);
    await mountPlayer(mount, page);
    await page.getByTestId('line-speaker').first().tap();

    const menu = page.getByTestId('line-speaker-menu');
    await expect(menu).toBeVisible();
    await expect(menu.getByRole('menuitem')).toHaveText(['Speaker 2', 'Someone new']);
    await expect(page.getByTestId('line-menu')).toHaveCount(0);
    await page.screenshot({ path: 'tmp/field-line-speaker-mobile.png' });

    await page.getByTestId('line-speaker-new').tap();
    await expect.poll(() => sent.length).toBe(1);
    expect(sent[0].line).toMatchObject({ first: 0, last: 1, was: 'Morning everyone.', speaker: 'new' });
  });

  test('pressing and holding a line edits it straight away', async ({ mount, page }) => {
    await mountPlayer(mount, page);
    await page
      .getByTestId('transcript-line')
      .first()
      .dispatchEvent('pointerdown', { pointerType: 'touch', isPrimary: true });
    await expect(page.getByTestId('line-editor')).toHaveValue('Morning everyone.', { timeout: 2000 });
    await expect(page.getByTestId('line-menu')).toHaveCount(0);
  });
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

// Writing a summary again: a refresh button beside the summary, shown on
// hover with a mouse and on tap on a phone.

const summarised = {
  ...recording,
  summary_long: 'A father and his daughter talk through her feeling lost.',
  summary_pending: false,
  resummarize_url: '/accounts/acct1/field/recordings/r1/resummarize',
};

async function captureResummaries(page) {
  const sent = [];
  await page.route('**/accounts/acct1/field/recordings/r1/resummarize', async (route) => {
    sent.push(route.request().method());
    await route.fulfill({ status: 200, contentType: 'application/json', body: '{}' });
  });
  return sent;
}

test('with a mouse, the refresh button shows on hover and asks for a new summary', async ({ mount, page }) => {
  const sent = await captureResummaries(page);
  await mount(RecordingViewer, { props: { recording: summarised } });
  const button = page.getByTestId('summary-refresh');
  await expect(button).toHaveCSS('opacity', '0');
  await page.getByTestId('field-recording-summary').hover();
  await expect(button).toHaveCSS('opacity', '1');
  await page.screenshot({ path: 'tmp/field-summary-refresh-desktop.png' });
  await button.click();
  await expect.poll(() => sent).toEqual(['POST']);
});

test('while a new summary is being written, the old one stays and the page says so', async ({ mount, page }) => {
  await mount(RecordingViewer, { props: { recording: { ...summarised, summary_pending: true } } });
  await expect(page.getByTestId('field-recording-summary')).toHaveText(summarised.summary_long);
  await expect(page.getByTestId('summary-pending')).toHaveText('Writing a new summary…');
  await expect(page.getByTestId('summary-refresh')).toBeDisabled();
});

test('with no way to redo it, there is no button', async ({ mount, page }) => {
  await mount(RecordingViewer, { props: { recording: { ...summarised, resummarize_url: null } } });
  await expect(page.getByTestId('field-recording-summary')).toBeVisible();
  await expect(page.getByTestId('summary-refresh')).toHaveCount(0);
});

test('after every attempt failed, the page says so and offers the button again', async ({ mount, page }) => {
  await mount(RecordingViewer, { props: { recording: { ...summarised, summary_failed: true } } });
  await expect(page.getByTestId('summary-failed')).toBeVisible();
  await expect(page.getByTestId('summary-refresh')).toBeEnabled();
  await expect(page.getByTestId('summary-refresh')).toHaveCSS('opacity', '1');
});

test('a request that fails without an answer says so rather than going quiet', async ({ mount, page }) => {
  await page.route('**/accounts/acct1/field/recordings/r1/resummarize', (route) =>
    route.fulfill({ status: 500, body: '' })
  );
  await mount(RecordingViewer, { props: { recording: summarised } });
  await page.getByTestId('field-recording-summary').hover();
  await page.getByTestId('summary-refresh').click();
  await expect(page.getByTestId('summary-error')).toBeVisible();
  await expect(page.getByTestId('summary-refresh')).toBeEnabled();
});

test.describe('summaries on a phone', () => {
  test.use({ hasTouch: true, isMobile: true, viewport: { width: 390, height: 844 } });

  test('tapping the summary shows the refresh button', async ({ mount, page }) => {
    const sent = await captureResummaries(page);
    await mount(RecordingViewer, { props: { recording: summarised } });
    await expect(page.getByTestId('summary-refresh')).toHaveCount(0);
    await page.getByTestId('field-recording-summary').tap();
    await expect(page.getByTestId('summary-refresh')).toBeVisible();
    await page.screenshot({ path: 'tmp/field-summary-refresh-mobile.png' });
    await page.getByTestId('summary-refresh').tap();
    await expect.poll(() => sent).toEqual(['POST']);
  });
});
