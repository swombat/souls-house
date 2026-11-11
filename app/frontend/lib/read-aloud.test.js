import { expect, test, vi } from 'vitest';
import { writable } from 'svelte/store';
import { createReadAloud, pageStorage, readAloudStored } from './read-aloud';
import { createEngineReader, createReplyReader } from './voice-mode-reader';

// The real reader, picker and player, with a stand-in <audio> element and a
// speech source that answers with a URL per message (no network, no engine).
function fakeAudio() {
  const audio = new EventTarget();
  audio.log = [];
  audio.refuse = false;
  audio.play = vi.fn(() => {
    audio.log.push(['play', audio.src]);
    if (!audio.refuse) return Promise.resolve();
    return Promise.reject(Object.assign(new Error('play() needs a tap'), { name: 'NotAllowedError' }));
  });
  audio.pause = vi.fn(() => audio.log.push(['pause']));
  audio.load = vi.fn();
  audio.removeAttribute = vi.fn(() => (audio.src = ''));
  audio.end = () => audio.dispatchEvent(new Event('ended'));
  return audio;
}

function memoryStorage() {
  const items = new Map();
  return {
    getItem: (k) => (items.has(k) ? items.get(k) : null),
    setItem: (k, v) => items.set(k, String(v)),
    removeItem: (k) => items.delete(k),
  };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));
const played = (audio) => audio.log.filter(([what]) => what === 'play').map(([, src]) => src);

let clock = Date.parse('2026-11-11T09:00:00Z');
function reply(id, extra = {}) {
  clock += 1000;
  return {
    id,
    role: 'assistant',
    voice_available: true,
    completed: true,
    content: `Reply ${id}`,
    created_at: new Date(clock).toISOString(),
    ...extra,
  };
}

function setup({ chatId = 'chat1', storage = memoryStorage(), voiceOpen = writable(false), initial = [] } = {}) {
  const audio = fakeAudio();
  let page = [...initial];
  const unlock = vi.fn();
  const source = { resolve: async (id) => ({ url: `/speech/${id}` }), close: vi.fn() };
  const states = [];
  const control = createReadAloud({
    chatId,
    messages: () => page,
    onstate: (s) => states.push(s),
    voiceOpen,
    unlock,
    storage,
    createReader: (messages, handlers) =>
      createEngineReader(messages, handlers, {
        create: (options) => createReplyReader({ ...options, audio, source }),
        engine: writable('elevenlabs'),
        preload: async () => {},
      }),
  });
  const land = async (...messages) => {
    page = [...page, ...messages];
    control.take(page);
    await flush();
  };
  const update = async (id, changes) => {
    page = page.map((m) => (m.id === id ? { ...m, ...changes } : m));
    control.take(page);
    await flush();
  };
  return { audio, control, unlock, states, storage, voiceOpen, land, update, page: () => page };
}

test('off by default: replies that land are not read', async () => {
  const t = setup({ initial: [reply('old')] });
  expect(t.control.state).toMatchObject({ on: false, speaking: null });
  await t.land(reply('a'));
  expect(played(t.audio)).toEqual([]);
});

test('on reads only replies that finish after the tap, once each, in page order', async () => {
  const t = setup({ initial: [reply('history-1'), reply('history-2')] });
  t.control.toggle();
  expect(t.unlock).toHaveBeenCalledTimes(1);
  expect(t.control.state.on).toBe(true);

  // A reply still streaming is read only once it completes, and in page order.
  await t.land(reply('a'), reply('b', { streaming: true, completed: false }), reply('c'));
  expect(played(t.audio)).toEqual(['/speech/a']);
  expect(t.control.state.speaking).toBe('a');
  t.audio.end();
  await flush();
  expect(played(t.audio)).toEqual(['/speech/a', '/speech/c']);
  await t.update('b', { streaming: false, completed: true });
  t.audio.end();
  await flush();
  expect(played(t.audio)).toEqual(['/speech/a', '/speech/c', '/speech/b']);

  // The same page taken again reads nothing twice; history was never read.
  t.audio.end();
  t.control.take(t.page());
  await flush();
  expect(played(t.audio)).toEqual(['/speech/a', '/speech/c', '/speech/b']);
  expect(t.control.state.speaking).toBe(null);
});

test('a person message, an unspeakable reply and a blank one are skipped', async () => {
  const t = setup();
  t.control.toggle();
  await t.land(
    { ...reply('mine'), role: 'user' },
    reply('no-voice', { voice_available: false }),
    reply('blank', { content: '  ' }),
    reply('ok')
  );
  expect(played(t.audio)).toEqual(['/speech/ok']);
});

test('off stops the reply playing at once and drops the queue', async () => {
  const t = setup();
  t.control.toggle();
  await t.land(reply('a'), reply('b'));
  expect(played(t.audio)).toEqual(['/speech/a']);
  t.control.toggle();
  expect(t.audio.pause).toHaveBeenCalled();
  expect(t.control.state).toMatchObject({ on: false, speaking: null });
  t.audio.end();
  await t.land(reply('c'));
  expect(played(t.audio)).toEqual(['/speech/a']);
});

test('voice mode opening pauses it; when it ends, reading resumes from that moment', async () => {
  const t = setup();
  t.control.toggle();
  await t.land(reply('a'));
  expect(played(t.audio)).toEqual(['/speech/a']);

  t.voiceOpen.set(true);
  expect(t.audio.pause).toHaveBeenCalled();
  expect(t.control.state).toMatchObject({ on: true, paused: true, speaking: null });
  await t.land(reply('during-voice-mode'));
  expect(played(t.audio)).toEqual(['/speech/a']);

  t.voiceOpen.set(false);
  expect(t.control.state.paused).toBe(false);
  await t.land(reply('after'));
  expect(played(t.audio)).toEqual(['/speech/a', '/speech/after']);
});

test('switching on while voice mode is open does not touch its audio element', () => {
  const t = setup({ voiceOpen: writable(true) });
  t.control.toggle();
  expect(t.unlock).not.toHaveBeenCalled();
  expect(t.control.state).toMatchObject({ on: true, paused: true });
});

test('the choice is per conversation and survives a reload of that conversation', async () => {
  const storage = memoryStorage();
  const first = setup({ chatId: 'chat1', storage });
  first.control.toggle();
  first.control.destroy();
  expect(readAloudStored('chat1', storage)).toBe(true);
  expect(readAloudStored('chat2', storage)).toBe(false);

  // The reload: on again, reading only what lands after it.
  const again = setup({ chatId: 'chat1', storage, initial: [reply('before-reload')] });
  expect(again.control.state.on).toBe(true);
  await again.land(reply('after-reload'));
  expect(played(again.audio)).toEqual(['/speech/after-reload']);

  again.control.toggle();
  expect(readAloudStored('chat1', storage)).toBe(false);
  expect(setup({ chatId: 'chat2', storage }).control.state.on).toBe(false);
});

test('leaving the page stops reading', async () => {
  const t = setup();
  t.control.toggle();
  await t.land(reply('a'));
  t.control.destroy();
  expect(t.audio.pause).toHaveBeenCalled();
  await t.land(reply('b'));
  expect(played(t.audio)).toEqual(['/speech/a']);
});

test('a reply the browser refuses waits behind "Tap to play"; that tap plays it', async () => {
  const t = setup();
  t.control.toggle();
  t.audio.refuse = true;
  await t.land(reply('a'));
  await flush();
  expect(t.control.state).toMatchObject({ on: true, blocked: true, note: '' });

  t.audio.refuse = false;
  t.control.playBlocked();
  await flush();
  expect(t.unlock).toHaveBeenCalledTimes(2);
  expect(t.control.state).toMatchObject({ on: true, blocked: false, speaking: 'a' });
  expect(played(t.audio)).toEqual(['/speech/a', '/speech/a']);

  // The speaker switches it off as usual.
  t.control.toggle();
  expect(t.control.state.on).toBe(false);
});

test('while a refused reply waits and another plays, the speaker stops (Mira, #888)', async () => {
  const t = setup();
  t.control.toggle();
  t.audio.refuse = true;
  await t.land(reply('a'));
  await flush();
  t.audio.refuse = false;
  await t.land(reply('b'));
  await flush();
  expect(t.control.state).toMatchObject({ on: true, blocked: true, speaking: 'b' });
  const before = played(t.audio).length;

  t.control.toggle();
  await flush();
  expect(t.control.state).toMatchObject({ on: false, blocked: false, speaking: null });
  expect(t.audio.pause).toHaveBeenCalled();
  expect(played(t.audio).length).toBe(before);
});

test('with every play refused, the speaker still switches off on the first tap', async () => {
  const t = setup();
  t.control.toggle();
  t.audio.refuse = true;
  await t.land(reply('a'));
  await flush();
  expect(t.control.state.blocked).toBe(true);

  t.control.toggle();
  await flush();
  expect(t.control.state).toMatchObject({ on: false, blocked: false });
  expect(played(t.audio)).toEqual(['/speech/a']);
  // "Tap to play" does nothing once off.
  t.control.playBlocked();
  await flush();
  expect(played(t.audio)).toEqual(['/speech/a']);
});

test('a storage policy that throws on reading localStorage leaves page-only state', () => {
  const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  Object.defineProperty(globalThis, 'localStorage', {
    configurable: true,
    get() {
      throw Object.assign(new Error('The operation is insecure.'), { name: 'SecurityError' });
    },
  });
  try {
    expect(pageStorage()).toBe(null);
    expect(readAloudStored('chat1')).toBe(false);
    const control = createReadAloud({
      chatId: 'chat1',
      messages: () => [],
      voiceOpen: writable(false),
      unlock: () => {},
      createReader: () => ({ take() {}, close() {}, replay() {} }),
    });
    expect(control.state.on).toBe(false);
    control.toggle();
    expect(control.state.on).toBe(true);
    control.destroy();
  } finally {
    if (descriptor) Object.defineProperty(globalThis, 'localStorage', descriptor);
    else delete globalThis.localStorage;
  }
});

test('a reply that cannot be read for another reason is a note, not "Tap to play"', async () => {
  const t = setup();
  t.control.toggle();
  t.audio.play.mockImplementationOnce(() => Promise.reject(new Error('Speech is not available.')));
  await t.land(reply('a'));
  await flush();
  expect(t.control.state).toMatchObject({ blocked: false, note: 'Speech is not available.' });
});
