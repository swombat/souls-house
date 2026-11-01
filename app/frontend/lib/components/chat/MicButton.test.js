import { cleanup, fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { isRecordingHeld } from '$lib/recording-guard';
import MicButton from './MicButton.svelte';

// A slow microphone prompt: getUserMedia resolves only when the test says so.
let pendingMic;
let recorders;
let tracks;

class FakeRecorder {
  constructor(stream) {
    this.stream = stream;
    this.state = 'inactive';
    this.mimeType = 'audio/webm';
    recorders.push(this);
  }
  static isTypeSupported() {
    return true;
  }
  start() {
    this.state = 'recording';
  }
  stop() {
    this.state = 'inactive';
    this.onstop?.();
  }
}

beforeEach(() => {
  recorders = [];
  tracks = [];
  pendingMic = [];
  globalThis.MediaRecorder = FakeRecorder;
  Object.defineProperty(globalThis.navigator, 'mediaDevices', {
    configurable: true,
    value: {
      getUserMedia: () =>
        new Promise((resolve) => {
          const track = { stop: vi.fn() };
          tracks.push(track);
          pendingMic.push(() => resolve({ getTracks: () => [track] }));
        }),
    },
  });
});

afterEach(() => cleanup());

test('clicks during a slow microphone prompt start one recording, and stopping it leaves nothing held', async () => {
  render(MicButton, { accountId: 'a', chatId: 'c', userId: 'u' });
  const button = document.querySelector('button');

  await fireEvent.click(button);
  await fireEvent.click(button);
  await fireEvent.click(button);
  expect(pendingMic).toHaveLength(1);

  pendingMic[0]();
  await tick();
  await tick();
  expect(recorders).toHaveLength(1);
  expect(recorders[0].state).toBe('recording');
  expect(isRecordingHeld()).toBe(true);

  await fireEvent.click(button);
  await tick();
  expect(recorders[0].state).toBe('inactive');
  expect(tracks[0].stop).toHaveBeenCalled();
  expect(isRecordingHeld()).toBe(false);
});

test('unmounting mid-recording stops the microphone and releases the hold', async () => {
  const { unmount } = render(MicButton, { accountId: 'a', chatId: 'c', userId: 'u' });
  await fireEvent.click(document.querySelector('button'));
  pendingMic[0]();
  await tick();
  await tick();
  expect(isRecordingHeld()).toBe(true);

  unmount();
  expect(recorders[0].state).toBe('inactive');
  expect(tracks[0].stop).toHaveBeenCalled();
  expect(isRecordingHeld()).toBe(false);
});

test('leaving while the microphone prompt is open, then granting it, starts nothing and holds nothing', async () => {
  const { unmount } = render(MicButton, { accountId: 'a', chatId: 'c', userId: 'u' });
  const button = document.querySelector('button');
  await fireEvent.click(button);
  await tick();
  expect(button).toHaveAttribute('title', 'Starting…');

  unmount();
  pendingMic[0]();
  await tick();
  await tick();
  expect(recorders).toHaveLength(0);
  expect(tracks[0].stop).toHaveBeenCalled();
  expect(isRecordingHeld()).toBe(false);
});
