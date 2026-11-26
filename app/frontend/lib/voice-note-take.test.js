import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import { createTake, STOP_FALLBACK_MS } from './voice-note-take.js';

let recorders;
let track;
let grant;

class FakeRecorder {
  constructor(stream, options) {
    this.stream = stream;
    this.state = 'inactive';
    this.mimeType = options?.mimeType || 'audio/webm';
    recorders.push(this);
  }
  static isTypeSupported(type) {
    return type === 'audio/webm';
  }
  start() {
    this.state = 'recording';
  }
  stop() {
    this.state = 'inactive';
  }
  deliver(text) {
    this.ondataavailable?.({ data: new Blob([text]) });
  }
}

function setup(overrides = {}) {
  const ended = vi.fn();
  const failed = vi.fn();
  const live = vi.fn();
  const take = createTake({
    onLive: live,
    onEnded: ended,
    onFailed: failed,
    media: () => ({ getUserMedia: () => grant() }),
    Recorder: () => FakeRecorder,
    ...overrides,
  });
  return { take, ended, failed, live };
}

beforeEach(() => {
  vi.useFakeTimers();
  recorders = [];
  track = { stop: vi.fn(), onended: null };
  const stream = { getTracks: () => [track], getAudioTracks: () => [track] };
  grant = () => Promise.resolve(stream);
});

afterEach(() => vi.useRealTimers());

test('an error before the last data still ends the take with that data, once stop arrives', async () => {
  const { take, ended } = setup();
  await take.start();
  const recorder = recorders[0];
  // The browser goes inactive and reports an error first…
  recorder.state = 'inactive';
  recorder.onerror();
  expect(ended).not.toHaveBeenCalled();
  // …then hands over the only audio there is, then stops.
  recorder.deliver('the whole thought');
  recorder.onstop();
  expect(ended).toHaveBeenCalledOnce();
  const { chunks, reason } = ended.mock.calls[0][0];
  expect(chunks).toHaveLength(1);
  expect(reason).toMatch('stopped unexpectedly');
  expect(track.stop).toHaveBeenCalled();
  // A late second stop does nothing.
  recorder.onstop();
  expect(ended).toHaveBeenCalledOnce();
});

test('a stop that never comes is covered by a bounded fallback', async () => {
  const { take, ended } = setup();
  await take.start();
  recorders[0].deliver('words');
  take.stop();
  expect(ended).not.toHaveBeenCalled();
  vi.advanceTimersByTime(STOP_FALLBACK_MS);
  expect(ended).toHaveBeenCalledOnce();
  expect(ended.mock.calls[0][0].reason).toBe('');
});

test('a take the browser stops on its own says so', async () => {
  const { take, ended } = setup();
  await take.start();
  recorders[0].deliver('half');
  recorders[0].state = 'inactive';
  recorders[0].onstop();
  expect(ended.mock.calls[0][0].reason).toMatch('stopped on its own');
});

test('disposing while the permission prompt is still open closes the mic it later grants', async () => {
  let resolve;
  grant = () => new Promise((r) => (resolve = r));
  const { take, live, failed } = setup();
  const starting = take.start();
  take.dispose();
  resolve({ getTracks: () => [track], getAudioTracks: () => [track] });
  await starting;
  expect(track.stop).toHaveBeenCalled();
  expect(recorders).toHaveLength(0);
  expect(live).not.toHaveBeenCalled();
  expect(failed).not.toHaveBeenCalled();
});

test('a recorder that throws on start fails cleanly and lets go of the mic', async () => {
  class Throws extends FakeRecorder {
    start() {
      throw new Error('NotSupportedError');
    }
  }
  const { take, failed, live } = setup({ Recorder: () => Throws });
  await take.start();
  expect(failed).toHaveBeenCalledWith('Could not start recording');
  expect(live).not.toHaveBeenCalled();
  expect(track.stop).toHaveBeenCalled();
});

test('disposing mid-take stops the recorder and the mic and reports nothing', async () => {
  const { take, ended } = setup();
  await take.start();
  take.dispose();
  expect(recorders[0].state).toBe('inactive');
  expect(track.stop).toHaveBeenCalled();
  vi.advanceTimersByTime(STOP_FALLBACK_MS * 2);
  expect(ended).not.toHaveBeenCalled();
});
