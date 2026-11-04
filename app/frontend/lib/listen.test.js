import { get } from 'svelte/store';
import { beforeEach, expect, test, vi } from 'vitest';

// Listen's page-level owner (Mira's review of #790): its state survives a
// message refresh because it is not on the message; an engine change or
// leaving the conversation (resetListen) cancels what is being made and a
// result that finishes afterwards is ignored; every made URL lives until the
// reset, so no player loses its audio to a cache limit.
let answers;
let made;
let revoked;
let signals;
vi.mock('$lib/speech-source', () => ({
  createSpeechSource: ({ keep }) => {
    const urls = [];
    return {
      keep,
      resolve: (id, { signal }) => {
        signals.push(signal);
        return answers(id, signal).then((answer) => {
          if (answer.engine === 'phonon') {
            const url = `blob:${id}:${made.length}`;
            made.push(url);
            urls.push(url);
            // As the real source does: beyond `keep`, the oldest is released.
            while (urls.length > keep) revoked.push(urls.shift());
            return { url, engine: 'phonon' };
          }
          return answer;
        });
      },
      close: () => urls.forEach((url) => revoked.push(url)),
    };
  },
}));

const { listen, listenState, resetListen } = await import('./listen');

beforeEach(() => {
  made = [];
  revoked = [];
  signals = [];
  answers = async () => ({ engine: 'phonon' });
  resetListen();
  revoked = [];
});

test('a Phonon Listen ends ready with its own URL, kept in state the page owns', async () => {
  await listen('m1');
  expect(get(listenState).m1).toEqual({ status: 'ready', url: 'blob:m1:0' });
  await listen('m1');
  expect(made).toHaveLength(1);
});

test('more than 24 Listens keep every URL: none is released while the page holds it', async () => {
  for (let i = 0; i < 30; i += 1) await listen(`m${i}`);
  expect(made).toHaveLength(30);
  expect(revoked).toEqual([]);
  expect(get(listenState).m0.url).toBe('blob:m0:0');
});

test('an engine change mid-synthesis aborts it, and the late result never plays', async () => {
  let finish;
  answers = () => new Promise((resolve) => (finish = resolve));
  const pending = listen('m1');
  expect(get(listenState).m1).toEqual({ status: 'loading' });

  resetListen();
  expect(signals[0].aborted).toBe(true);
  finish({ engine: 'phonon' });
  await pending;
  expect(get(listenState)).toEqual({});
});

test('a reset releases every URL Listen made, so its players unmount with nothing playing on', async () => {
  await listen('m1');
  await listen('m2');
  resetListen();
  expect(revoked.sort()).toEqual(made.sort());
  expect(get(listenState)).toEqual({});
});

test('under ElevenLabs the stored-audio request decides: made, pending, or the reason', async () => {
  answers = async () => ({ engine: 'elevenlabs', url: null });
  await listen('a', { postVoice: async () => ({ url: '/stored.mp3' }) });
  await listen('b', { postVoice: async () => ({ pending: true }) });
  await listen('c', { postVoice: async () => ({ error: 'no key of its own' }) });
  expect(get(listenState)).toEqual({
    a: { status: 'stored', url: '/stored.mp3' },
    b: { status: 'pending' },
    c: { status: 'error', error: 'no key of its own' },
  });
});

test('a failure is shown with its reason and Listen can be pressed again', async () => {
  answers = async () => {
    throw new Error("This browser can't run Phonon");
  };
  await listen('m1');
  expect(get(listenState).m1).toEqual({ status: 'error', error: "This browser can't run Phonon" });
  answers = async () => ({ engine: 'phonon' });
  await listen('m1');
  expect(get(listenState).m1.status).toBe('ready');
});
