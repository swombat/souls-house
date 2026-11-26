import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';

const post = vi.hoisted(() => vi.fn());
vi.mock('@inertiajs/svelte', () => ({ router: { post, on: vi.fn(), reload: vi.fn() } }));
const upload = vi.hoisted(() => vi.fn());
vi.mock('$lib/field-direct-upload', () => ({ directUpload: upload }));
const hold = vi.hoisted(() => ({ held: [], calls: [] }));
vi.mock('$lib/recording-guard', () => ({
  holdForRecording: (options = {}) => {
    const entry = { options, released: false };
    hold.calls.push(entry);
    hold.held.push(entry);
    return () => {
      entry.released = true;
      hold.held = hold.held.filter((h) => h !== entry);
    };
  },
}));
import VoiceNoteDialog from './VoiceNoteDialog.svelte';

let recorders;
let tracks;

class FakeRecorder {
  constructor(stream, options) {
    this.stream = stream;
    this.state = 'inactive';
    this.mimeType = options?.mimeType || 'audio/webm';
    recorders.push(this);
  }
  static isTypeSupported(type) {
    return type === 'audio/webm;codecs=opus';
  }
  start() {
    this.state = 'recording';
  }
  say(text) {
    this.ondataavailable?.({ data: new Blob([text], { type: this.mimeType }) });
  }
  stop() {
    this.state = 'inactive';
    this.onstop?.();
  }
}

function postFinishedWith(outcome, errors = {}) {
  const options = post.mock.calls.at(-1)[2];
  if (outcome === 'success') options.onSuccess();
  if (outcome === 'error') options.onError(errors);
  options.onFinish?.();
}

beforeEach(() => {
  recorders = [];
  tracks = [];
  hold.held = [];
  hold.calls = [];
  post.mockReset();
  upload.mockReset();
  globalThis.MediaRecorder = FakeRecorder;
  globalThis.URL.createObjectURL = vi.fn(() => 'blob:take');
  globalThis.URL.revokeObjectURL = vi.fn();
  Object.defineProperty(globalThis.navigator, 'mediaDevices', {
    configurable: true,
    value: {
      getUserMedia: vi.fn(async () => {
        const track = { stop: vi.fn(), onended: null };
        tracks.push(track);
        return { getTracks: () => [track], getAudioTracks: () => [track] };
      }),
    },
  });
});

afterEach(() => cleanup());

async function settle() {
  for (let i = 0; i < 5; i++) await tick();
}

async function openRecording() {
  render(VoiceNoteDialog, { open: true, accountId: 'acc' });
  await settle();
  expect(screen.getByTestId('voice-note-live')).toBeInTheDocument();
  return recorders.at(-1);
}

test('opening starts recording at once; Stop shows the take, and Save sends it as a recording with a bare type', async () => {
  const recorder = await openRecording();
  expect(recorder.state).toBe('recording');
  expect(hold.held).toHaveLength(1);
  recorder.say('an idea');

  await fireEvent.click(screen.getByTestId('voice-note-stop'));
  await settle();
  expect(screen.getByTestId('voice-note-playback')).toHaveAttribute('src', 'blob:take');
  expect(tracks[0].stop).toHaveBeenCalled();
  expect(screen.getByLabelText('Title').value).toMatch(/^Voice note · \d{1,2} \w{3}, \d{2}:\d{2}$/);

  upload.mockResolvedValue({ signed_id: 'signed' });
  await fireEvent.input(screen.getByLabelText('Title'), { target: { value: 'Ticket idea' } });
  await fireEvent.click(screen.getByTestId('voice-note-save'));
  await settle();

  const [file, url] = upload.mock.calls[0];
  expect([file.type, file.name, url]).toEqual([
    'audio/webm',
    'Ticket idea.webm',
    '/accounts/acc/field/recordings/uploads',
  ]);
  const [path, body] = post.mock.calls[0];
  expect(path).toBe('/accounts/acc/field/recordings');
  expect(body.field_recording).toMatchObject({ upload_id: 'signed', title: 'Ticket idea', expected_speakers: 1 });
  expect(body.field_recording.recorded_at).toMatch(/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/);
  // Our own save must not meet "discard the recording?": only a quiet hold is left.
  expect(hold.held.map((h) => h.options.warn)).toEqual([false]);

  postFinishedWith('success');
  await settle();
  expect(hold.held).toHaveLength(0);
});

test('an upload that fails keeps the take to try again', async () => {
  const recorder = await openRecording();
  recorder.say('words');
  await fireEvent.click(screen.getByTestId('voice-note-stop'));
  await settle();

  upload.mockRejectedValueOnce('Storage is unavailable.');
  await fireEvent.click(screen.getByTestId('voice-note-save'));
  await settle();
  expect(screen.getByRole('alert')).toHaveTextContent('Storage is unavailable.');
  expect(screen.getByTestId('voice-note-playback')).toBeInTheDocument();
  expect(screen.getByTestId('voice-note-save')).toHaveTextContent('Try again');
  expect(hold.held.map((h) => h.options.warn)).toEqual([undefined]);

  upload.mockResolvedValueOnce({ signed_id: 'again' });
  await fireEvent.click(screen.getByTestId('voice-note-save'));
  await settle();
  expect(post.mock.calls[0][1].field_recording.upload_id).toBe('again');
});

test('a take the browser ends on its own goes to review with what was captured, and says so', async () => {
  const recorder = await openRecording();
  recorder.say('half a thought');
  // Safari ends the track when the screen locks; the recorder then stops.
  tracks[0].onended();
  await settle();
  expect(screen.queryByTestId('voice-note-live')).not.toBeInTheDocument();
  expect(screen.getByTestId('voice-note-playback')).toBeInTheDocument();
  expect(screen.getByRole('status')).toHaveTextContent('The microphone stopped');
});

test('a denied microphone says why and holds nothing', async () => {
  navigator.mediaDevices.getUserMedia = vi.fn(async () => {
    throw Object.assign(new Error('no'), { name: 'NotAllowedError' });
  });
  render(VoiceNoteDialog, { open: true, accountId: 'acc' });
  await settle();
  expect(screen.getByRole('alert')).toHaveTextContent('Microphone access denied');
  expect(hold.held).toHaveLength(0);
});

test('discarding a take stops the microphone and lets go of the page', async () => {
  const recorder = await openRecording();
  recorder.say('never mind');
  await fireEvent.click(screen.getByTestId('voice-note-stop'));
  await settle();
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  await fireEvent.click(screen.getByTestId('voice-note-discard'));
  await settle();
  expect(upload).not.toHaveBeenCalled();
  expect(hold.held).toHaveLength(0);
  expect(URL.revokeObjectURL).toHaveBeenCalledWith('blob:take');
});

test('a save that is never answered can be retried safely, re-sending the same upload', async () => {
  const recorder = await openRecording();
  recorder.say('idea');
  await fireEvent.click(screen.getByTestId('voice-note-stop'));
  await settle();
  upload.mockResolvedValue({ signed_id: 'once' });
  await fireEvent.click(screen.getByTestId('voice-note-save'));
  await settle();
  expect(screen.getByTestId('voice-note-progress')).toHaveTextContent('Saving…');

  // A network failure: Inertia finishes without success or error.
  postFinishedWith('neither');
  await settle();
  expect(screen.getByRole('alert')).toHaveTextContent("couldn't confirm the save");
  expect(screen.getByTestId('voice-note-save')).not.toBeDisabled();
  expect(hold.held.map((h) => h.options.warn)).toEqual([undefined]);

  await fireEvent.click(screen.getByTestId('voice-note-save'));
  await settle();
  expect(upload).toHaveBeenCalledOnce();
  expect(post.mock.calls.map((call) => call[1].field_recording.upload_id)).toEqual(['once', 'once']);

  // Refused: the first may have landed, or the upload may have expired. Say
  // the real reason and keep the uncertainty for the next attempt too.
  postFinishedWith('error', { audio: "That upload can't be used." });
  await settle();
  expect(screen.getByRole('alert')).toHaveTextContent("still can't confirm the first save");
  expect(screen.getByRole('alert')).toHaveTextContent("That upload can't be used.");
  expect(screen.getByRole('alert')).toHaveTextContent('Check Recordings');

  await fireEvent.click(screen.getByTestId('voice-note-save'));
  await settle();
  postFinishedWith('neither');
  await settle();
  expect(screen.getByRole('alert')).toHaveTextContent("still can't confirm the first save");
  expect(screen.getByRole('alert')).not.toHaveTextContent('Trying again is safe');
});

test('an answer to a save that arrives after the dialog has gone holds nothing', async () => {
  const component = render(VoiceNoteDialog, { open: true, accountId: 'acc' });
  await settle();
  recorders.at(-1).say('idea');
  await fireEvent.click(screen.getByTestId('voice-note-stop'));
  await settle();
  upload.mockResolvedValue({ signed_id: 'late' });
  await fireEvent.click(screen.getByTestId('voice-note-save'));
  await settle();
  const options = post.mock.calls.at(-1)[2];
  component.unmount();
  expect(hold.held).toHaveLength(0);

  options.onError({ audio: 'late' });
  options.onFinish();
  options.onSuccess();
  expect(hold.held).toHaveLength(0);
});

test('leaving the page mid-take lets go of the microphone and the page hold', async () => {
  const component = render(VoiceNoteDialog, { open: true, accountId: 'acc' });
  await settle();
  expect(hold.held).toHaveLength(1);
  component.unmount();
  expect(tracks[0].stop).toHaveBeenCalled();
  expect(hold.held).toHaveLength(0);
});

test('a dialog closed while the permission prompt is open lets go of the mic it is later given', async () => {
  let grant;
  navigator.mediaDevices.getUserMedia = vi.fn(
    () =>
      new Promise((resolve) => {
        const track = { stop: vi.fn(), onended: null };
        tracks.push(track);
        grant = () => resolve({ getTracks: () => [track], getAudioTracks: () => [track] });
      })
  );
  const component = render(VoiceNoteDialog, { open: true, accountId: 'acc' });
  await settle();
  component.unmount();
  grant();
  await settle();
  expect(tracks[0].stop).toHaveBeenCalled();
  expect(recorders).toHaveLength(0);
  expect(hold.held).toHaveLength(0);
});
