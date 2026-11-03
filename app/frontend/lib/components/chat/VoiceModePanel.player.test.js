import { cleanup, render, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';

// The panel with the REAL reply picker and the REAL player (#748, Mira's
// round 1): only the microphone, the transcriber and the <audio> element are
// stand-ins. The audio log is what a person would hear, in order.
let callbacks;
vi.mock('$lib/voice-mode-capture', () => ({
  captureSupported: () => true,
  startCapture: vi.fn(async (options) => {
    callbacks = options;
    return { muted: false, mute: () => {}, flush: () => {}, stop: vi.fn(async () => {}) };
  }),
}));

let transcriber;
vi.mock('$lib/voice-mode-realtime', () => ({
  createTranscriber: vi.fn(() => {
    transcriber = {
      results: [],
      connect: vi.fn(async () => {}),
      begin: vi.fn(),
      append: vi.fn(),
      discard: vi.fn(),
      commit: vi.fn(() => Promise.resolve(transcriber.results.shift())),
      close: vi.fn(),
    };
    return transcriber;
  }),
}));

let audio;
function fakeAudio() {
  const element = new EventTarget();
  element.log = [];
  element.play = vi.fn(() => {
    element.log.push(element.src);
    return Promise.resolve();
  });
  element.pause = vi.fn();
  element.load = vi.fn();
  element.removeAttribute = vi.fn(() => (element.src = ''));
  element.end = () => element.dispatchEvent(new Event('ended'));
  return element;
}
vi.mock('$lib/voice-mode-playback', async (importOriginal) => {
  const actual = await importOriginal();
  return { ...actual, createPlayer: (options) => actual.createPlayer({ ...options, audio }) };
});

import VoiceModePanel from './VoiceModePanel.svelte';

let clock = 0;
const reply = (id) => ({
  id,
  role: 'assistant',
  voice_available: true,
  completed: true,
  streaming: false,
  content: `Reply ${id}.`,
  created_at: new Date(Date.UTC(2026, 10, 2, 22, 0, clock++)).toISOString(),
});
const heard = () => audio.log.map((src) => src.replace(/^\/messages\/(.*)\/speech$/, '$1'));
const props = { accountId: 'acc', chatId: 'chat', userId: 7 };

beforeEach(() => {
  audio = fakeAudio();
  callbacks = null;
  globalThis.fetch = vi.fn(async () => ({ ok: true, status: 201, json: async () => ({ id: 'sent' }) }));
  document.head.innerHTML = '<meta name="csrf-token" content="token">';
});
afterEach(cleanup);

async function openWithTwoReplies() {
  const view = render(VoiceModePanel, { ...props, messages: [] });
  await waitFor(() => expect(callbacks).toBeTruthy());
  const a = reply('A');
  const b = reply('B');
  await view.rerender({ ...props, messages: [a, b] });
  expect(heard()).toEqual(['A']); // A playing, B queued behind it
  return { ...view, a, b };
}

test('noise that is not speech loses nothing: A playing and B queued are both read again, A from the start (under 5 s in)', async () => {
  const { a, b } = await openWithTwoReplies();
  callbacks.onspeechstart(new Float32Array(10));
  callbacks.ondiscard(120);
  expect(heard()).toEqual(['A', 'A']);
  audio.end();
  expect(heard()).toEqual(['A', 'A', 'B']);
  audio.end();
  expect(heard()).toEqual(['A', 'A', 'B']);
  expect([a.id, b.id]).toEqual(['A', 'B']);
});

test('a reply landing during the noise is read after the restored sequence', async () => {
  const { rerender, a, b } = await openWithTwoReplies();
  callbacks.onspeechstart(new Float32Array(10));
  await rerender({ ...props, messages: [a, b, reply('C')] });
  callbacks.ondiscard(120);
  audio.end();
  audio.end();
  expect(heard()).toEqual(['A', 'A', 'B', 'C']);
});

test('a sent turn loses nothing (#758): A cut off early starts again, B follows, then the next reply', async () => {
  const { rerender, a, b } = await openWithTwoReplies();
  transcriber.results.push('Something else.');
  callbacks.onspeechstart(new Float32Array(10));
  callbacks.onturn(1500);
  await waitFor(() => expect(heard()).toEqual(['A', 'A']));
  await rerender({ ...props, messages: [a, b, reply('D')] });
  audio.end();
  expect(heard()).toEqual(['A', 'A', 'B']);
  audio.end();
  expect(heard()).toEqual(['A', 'A', 'B', 'D']);
});

test('a reply spoken over after five seconds plays on from where it paused, on the same audio (#758)', async () => {
  const { b } = await openWithTwoReplies();
  audio.currentTime = 20;
  let sources = 0;
  const src = audio.src;
  Object.defineProperty(audio, 'src', {
    configurable: true,
    get: () => src,
    set: () => (sources += 1),
  });
  transcriber.results.push('Hang on.');
  callbacks.onspeechstart(new Float32Array(10));
  callbacks.onturn(1500);
  await waitFor(() => expect(audio.play).toHaveBeenCalledTimes(2));
  expect(audio.pause).toHaveBeenCalled();
  expect(sources).toBe(0);
  expect(audio.currentTime).toBe(20);
  expect(b.id).toBe('B');
});
