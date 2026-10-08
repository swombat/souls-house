import { test, expect } from '@playwright/experimental-ct-svelte';
import RecordingPage from '../../app/frontend/pages/field/recordings/show.svelte';
import FieldPage from '../../app/frontend/pages/field/index.svelte';

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
    id: 's1', label: 'speaker_0', position: 0, default_name: 'Speaker 1', name: 'Sam', named: true,
    voice_id: 'v1', naming_source: 'human', talk_ms: 1_200_000, clip_start_ms: 0, clip_end_ms: 900,
  },
  {
    id: 's2', label: 'speaker_1', position: 1, default_name: 'Speaker 2', name: 'Speaker 2', named: false,
    voice_id: null, naming_source: null, talk_ms: 2_100_000, clip_start_ms: 3000, clip_end_ms: 6200,
  },
];

test('the transcript page shows names, unnamed speakers and turns', async ({ mount, page }) => {
  const component = await mount(RecordingPage, {
    props: {
      recording,
      speakers,
      voices: [{ id: 'v1', name: 'Sam', member: true }, { id: 'v2', name: 'Priya', member: false }],
      members_without_voice: [],
      my_voice_id: 'v1',
      show_you_hint: false,
      account,
    },
  });

  await expect(component).toContainText('Board call with Priya and Tomás');
  await expect(component).toContainText('Speaker 2');
  await expect(component).toContainText('Shall we start with the venue?');
  await expect(component).not.toContainText('thinks');
  await expect(component).not.toContainText('voice print');
  await page.screenshot({ path: 'tmp/field-recording-show.png', fullPage: true });
});

test('the "is one of these you?" hint shows when asked for', async ({ mount, page }) => {
  const component = await mount(RecordingPage, {
    props: { recording, speakers, voices: [], members_without_voice: [], my_voice_id: null, show_you_hint: true, account },
  });
  await expect(component).toContainText('Is one of these you?');
  await page.screenshot({ path: 'tmp/field-recording-hint.png', fullPage: true });
});

test('the Recordings tab lists recordings in plain words, with the allowance gauge', async ({ mount, page }) => {
  const component = await mount(FieldPage, {
    props: {
      files: [],
      notes: [],
      recordings: [
        recording,
        { ...recording, key: 'recording-r2', id: 'r2', title: 'Tuesday standup', status: 'transcribing', speaker_names: [] },
        {
          ...recording, key: 'recording-r3', id: 'r3', title: 'The long one', status: 'rejected', speaker_names: [],
          failure_reason: "This recording is 4 h 10 m. You have 3 h 20 m left this week. No estimate yet: other recordings are still transcribing.",
          retryable: true, dispatched: false,
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
