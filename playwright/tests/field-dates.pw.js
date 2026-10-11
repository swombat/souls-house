import { test, expect } from '@playwright/experimental-ct-svelte';
import RecordingViewer from '../../app/frontend/lib/components/field/RecordingViewer.svelte';
import FieldPage from '../../app/frontend/pages/field/index.svelte';

// Dates on Field items from the web (#292): changing a recording's date after
// upload, and the optional date on both upload forms. Names are made up.
const account = { id: 'acct1', name: 'Wren House' };

const recording = {
  key: 'recording-r1',
  kind: 'recording',
  id: 'r1',
  title: 'Board call with Priya',
  note: 'The venue question again.',
  status: 'transcribing',
  duration_ms: 600_000,
  filename: 'board-call.m4a',
  byte_size: 4_800_000,
  uploader_name: 'Sam',
  uploader_kind: 'human',
  speaker_names: [],
  retryable: false,
  show_url: '/accounts/acct1/field/recordings/r1',
  created_at: '2026-10-08T07:00:00Z',
  recorded_at: '2024-05-06T14:30:00+02:00',
};

const fieldProps = {
  items: [],
  field_empty: true,
  counts: { all: 0, files: 0, notes: 0, recordings: 0 },
  pagination: { page: 1, pages: 1, per_page: 50, total: 0 },
  recording_allowance: { limit_ms: 72_000_000, used_ms: 0, pending_ms: 0, window_days: 7 },
  tab: 'all',
  selected: null,
  account_name: 'Wren House',
  account,
};

const dialog = (page) => page.locator('[data-slot="dialog-content"]');

// ---------------------------------------------------------------------------
// Changing a recording's date

async function editRecording(mount, page, props) {
  const patches = [];
  await page.route('**/accounts/acct1/field/recordings/r1', async (route) => {
    if (route.request().method() === 'PATCH') patches.push(route.request().postDataJSON());
    await route.fulfill({ json: {} });
  });
  await mount(RecordingViewer, { props: { recording: props } });
  await page.getByRole('button', { name: 'Edit' }).click();
  return patches;
}

async function saveAndWait(page) {
  await page.getByRole('button', { name: 'Save' }).click();
  await expect(page.getByTestId('recording-edit-recorded-on')).toHaveCount(0);
}

test('editing only the title sends no recorded_at, so the time of day is kept', async ({ mount, page }) => {
  const patches = await editRecording(mount, page, recording);
  await expect(page.getByTestId('recording-edit-recorded-on')).toHaveValue('2024-05-06');
  await page.locator('#recording-edit-title').fill('Board call with Priya and Tomás');
  await saveAndWait(page);
  expect(patches).toHaveLength(1);
  expect(patches[0].field_recording).toEqual({
    title: 'Board call with Priya and Tomás',
    note: 'The venue question again.',
  });
});

test('changing the date sends the new day', async ({ mount, page }) => {
  const patches = await editRecording(mount, page, recording);
  await page.getByTestId('recording-edit-recorded-on').fill('2019-03-14');
  await saveAndWait(page);
  expect(patches).toHaveLength(1);
  expect(patches[0].field_recording).toMatchObject({ title: 'Board call with Priya', recorded_at: '2019-03-14' });
});

test('emptying the date sends an empty recorded_at, which clears it', async ({ mount, page }) => {
  const patches = await editRecording(mount, page, recording);
  await page.getByTestId('recording-edit-recorded-on').fill('');
  await saveAndWait(page);
  expect(patches).toHaveLength(1);
  expect(patches[0].field_recording.recorded_at).toBe('');
});

test('a recording without a date: the field starts empty and saving sends no date', async ({ mount, page }) => {
  const patches = await editRecording(mount, page, { ...recording, recorded_at: null });
  await expect(page.getByTestId('recording-edit-recorded-on')).toHaveValue('');
  await saveAndWait(page);
  expect(patches[0].field_recording).not.toHaveProperty('recorded_at');
});

// ---------------------------------------------------------------------------
// The date on "Bring in a recording"

async function fakeRecordingBackend(page) {
  const posts = [];
  await page.route('**/accounts/acct1/field/recordings/uploads', (route) =>
    route.fulfill({
      json: {
        id: 1,
        key: 'k1',
        filename: 'call.m4a',
        content_type: 'audio/mp4',
        byte_size: 10,
        checksum: 'x',
        signed_id: 'signed-1',
        direct_upload: { url: '/test-storage/1', headers: {} },
      },
    })
  );
  await page.route('**/test-storage/*', (route) => route.fulfill({ status: 204, body: '' }));
  await page.route('**/accounts/acct1/field/recordings', (route) => {
    posts.push(route.request().postDataJSON());
    return route.fulfill({ json: {} });
  });
  return posts;
}

const audioFile = { name: 'call.m4a', mimeType: 'audio/mp4', buffer: Buffer.from('not really audio') };

for (const [label, date, expected] of [
  ['with a date sends it as recorded_at', '2019-03-14', '2019-03-14'],
  ['without a date sends recorded_at null', '', null],
]) {
  test(`bringing in a recording ${label}`, async ({ mount, page }) => {
    await mount(FieldPage, { props: fieldProps });
    const posts = await fakeRecordingBackend(page);
    await page.getByTestId('field-add-recording').click();
    await dialog(page).locator('#recording-file').setInputFiles(audioFile);
    await dialog(page).locator('#recording-title').fill('Old call');
    if (date) await dialog(page).getByTestId('recording-recorded-on').fill(date);
    await dialog(page).getByRole('button', { name: 'Bring it in' }).click();
    await expect(dialog(page)).toHaveCount(0);
    expect(posts).toHaveLength(1);
    expect(posts[0].field_recording).toMatchObject({ upload_id: 'signed-1', title: 'Old call', recorded_at: expected });
  });
}

// ---------------------------------------------------------------------------
// The date on "Add a file to the Field"

const textFile = { name: 'transcript.txt', mimeType: 'text/plain', buffer: Buffer.from('An old transcript.') };

async function addFile(mount, page, { date, respond }) {
  const bodies = [];
  await mount(FieldPage, { props: fieldProps });
  await page.route('**/accounts/acct1/field/files', (route) => {
    bodies.push(route.request().postData());
    return respond(route);
  });
  await page.getByTestId('field-add-file').click();
  await dialog(page).locator('#field-file').setInputFiles(textFile);
  if (date) await dialog(page).getByTestId('field-file-date').fill(date);
  await dialog(page).getByRole('button', { name: 'Add to the Field' }).click();
  return bodies;
}

const part = (name, value) => new RegExp(`name="${name.replace(/[[\]]/g, '\\$&')}"\\r\\n\\r\\n${value}\\r\\n`);

test('adding a file with a date sends field_file[dated_at] in the multipart body', async ({ mount, page }) => {
  const bodies = await addFile(mount, page, { date: '2019-03-14', respond: (route) => route.fulfill({ json: {} }) });
  await expect(dialog(page)).toHaveCount(0);
  expect(bodies).toHaveLength(1);
  expect(bodies[0]).toMatch(part('field_file[dated_at]', '2019-03-14'));
  expect(bodies[0]).toContain('filename="transcript.txt"');
});

test('adding a file without a date sends no dated_at', async ({ mount, page }) => {
  const bodies = await addFile(mount, page, { date: '', respond: (route) => route.fulfill({ json: {} }) });
  await expect(dialog(page)).toHaveCount(0);
  expect(bodies).toHaveLength(1);
  expect(bodies[0]).not.toContain('field_file[dated_at]');
});

test('a date the server refuses keeps the dialog open with its message', async ({ mount, page }) => {
  const message = 'Dated at must be an ISO 8601 date or time, like 2019-03-14';
  await addFile(mount, page, {
    date: '2019-03-14',
    respond: (route) => route.fulfill({ status: 422, json: { errors: { dated_at: message } } }),
  });
  await expect(dialog(page).getByRole('alert')).toHaveText(message);
  await expect(dialog(page).getByTestId('field-file-date')).toHaveValue('2019-03-14');
});
