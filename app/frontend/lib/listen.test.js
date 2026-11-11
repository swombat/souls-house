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
      resolve: (id, { signal, onAudio }) => {
        signals.push(signal);
        return answers(id, signal, onAudio).then((answer) => {
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

// Playing as it is made (YNwVle). A fake stream player records what Listen
// does with it; the real one is tested in stream-player.test.js.
function fakeStream() {
  const made = [];
  return {
    made,
    factory: ({ onended }) => {
      const player = {
        pushed: [],
        finished: false,
        stopped: false,
        push: vi.fn((samples, rate) => player.pushed.push([samples, rate])),
        finish: vi.fn(() => (player.finished = true)),
        stop: vi.fn(() => (player.stopped = true)),
        end: () => onended(),
      };
      made.push(player);
      return player;
    },
  };
}

test('a Phonon Listen plays from the first chunk, in order, and keeps the WAV for afterwards', async () => {
  const streams = fakeStream();
  let more;
  answers = (id, signal, onAudio) => {
    onAudio(new Float32Array([0.1]), 24000);
    return new Promise((resolve) => {
      more = () => {
        onAudio(new Float32Array([0.2]), 24000);
        onAudio(new Float32Array([0.3]), 24000);
        resolve({ engine: 'phonon' });
      };
    });
  };
  const pending = listen('m1', { stream: streams.factory });
  const [player] = streams.made;
  // Sounding before the message is all made: no URL yet, the stream is the player.
  expect(get(listenState).m1).toEqual({ status: 'streaming', stream: player });
  expect(player.finished).toBe(false);
  more();
  await pending;
  expect(player.pushed.map(([samples, rate]) => [samples[0], rate])).toEqual([
    [Math.fround(0.1), 24000],
    [Math.fround(0.2), 24000],
    [Math.fround(0.3), 24000],
  ]);
  expect(get(listenState).m1).toEqual({ status: 'streaming', stream: player, url: 'blob:m1:0' });
  expect(player.finish).toHaveBeenCalled();

  // Heard to the end: the ordinary player takes the kept WAV, not starting by itself.
  player.end();
  expect(get(listenState).m1).toEqual({ status: 'ready', url: 'blob:m1:0', heard: true });
  // Listen again replays that WAV: nothing is made a second time.
  await listen('m1', { stream: streams.factory });
  expect(made).toHaveLength(1);
  expect(streams.made).toHaveLength(1);
});

test('a reset mid-stream stops the sound and aborts the making, and late chunks go nowhere', async () => {
  const streams = fakeStream();
  let onAudioLater;
  let finish;
  answers = (id, signal, onAudio) => {
    onAudio(new Float32Array([0.1]), 24000);
    onAudioLater = onAudio;
    return new Promise((resolve) => (finish = resolve));
  };
  const pending = listen('m1', { stream: streams.factory });
  const [player] = streams.made;
  expect(get(listenState).m1.status).toBe('streaming');

  resetListen();
  expect(player.stop).toHaveBeenCalled();
  expect(signals[0].aborted).toBe(true);
  onAudioLater(new Float32Array([0.2]), 24000);
  finish({ engine: 'phonon' });
  await pending;
  expect(player.pushed).toHaveLength(1);
  expect(player.finish).not.toHaveBeenCalled();
  expect(get(listenState)).toEqual({});
});

test('a failure mid-stream stops the sound and says why', async () => {
  const streams = fakeStream();
  answers = async (id, signal, onAudio) => {
    onAudio(new Float32Array([0.1]), 24000);
    throw new Error('The graphics device Phonon was using went away.');
  };
  await listen('m1', { stream: streams.factory });
  expect(streams.made[0].stop).toHaveBeenCalled();
  expect(get(listenState).m1).toEqual({ status: 'error', error: 'The graphics device Phonon was using went away.' });
});

test('audio already made (no chunks) plays through the ordinary player, and the unused stream is released', async () => {
  const streams = fakeStream();
  await listen('m1', { stream: streams.factory });
  expect(streams.made[0].stop).toHaveBeenCalled();
  expect(get(listenState).m1).toEqual({ status: 'ready', url: 'blob:m1:0' });
});

test('under ElevenLabs the stream made in the tap is released unused', async () => {
  const streams = fakeStream();
  answers = async () => ({ engine: 'elevenlabs', url: null });
  await listen('a', { postVoice: async () => ({ pending: true }), stream: streams.factory });
  expect(streams.made[0].stop).toHaveBeenCalled();
  expect(streams.made[0].pushed).toEqual([]);
});

test('without Web Audio, Listen waits for the whole message as before', async () => {
  let given;
  answers = async (id, signal, onAudio) => {
    given = onAudio;
    return { engine: 'phonon' };
  };
  await listen('m1', { stream: () => null });
  expect(given).toBeUndefined();
  expect(get(listenState).m1).toEqual({ status: 'ready', url: 'blob:m1:0' });
});
