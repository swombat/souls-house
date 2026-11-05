import { describe, expect, test, vi } from 'vitest';
import { createHeldTurns, heldStorageKey } from './voice-mode-held';

function memoryStorage(initial = {}) {
  const data = { ...initial };
  return {
    data,
    getItem: (key) => (key in data ? data[key] : null),
    setItem: (key, value) => (data[key] = value),
    removeItem: (key) => delete data[key],
  };
}

describe('createHeldTurns', () => {
  test('sends from the front in order and stops at the first failure', async () => {
    const outcomes = { a: [{ ok: false, error: 'offline' }, { ok: true }], b: [{ ok: true }] };
    const sent = [];
    const held = createHeldTurns({
      storage: memoryStorage(),
      key: 'k',
      deliver: async (item) => {
        sent.push(item.text);
        return outcomes[item.text].shift();
      },
    });
    held.hold({ text: 'a', error: 'timeout' });
    held.hold({ text: 'b', state: 'waiting' });
    expect(held.list().map((t) => t.state)).toEqual(['failed', 'waiting']);

    await held.drain();
    expect(sent).toEqual(['a']);
    expect(held.list()).toMatchObject([
      { text: 'a', state: 'failed', error: 'offline' },
      { text: 'b', state: 'waiting' },
    ]);

    await held.drain();
    expect(sent).toEqual(['a', 'a', 'b']);
    expect(held.size).toBe(0);
  });

  test('an automatic retry is tried once per turn; Retry always tries', async () => {
    const deliver = vi.fn(async () => ({ ok: false, error: 'still down' }));
    const held = createHeldTurns({ storage: memoryStorage(), key: 'k', deliver });
    held.hold({ text: 'x', error: 'down' });
    await held.drain({ auto: true });
    await held.drain({ auto: true });
    expect(deliver).toHaveBeenCalledTimes(1);
    await held.drain();
    expect(deliver).toHaveBeenCalledTimes(2);
  });

  test('a turn transcribed again with no words is dropped; a fatal answer stops the queue', async () => {
    const answers = [
      { ok: false, dropped: true, text: '' },
      { ok: false, fatal: true, error: 'mode off' },
    ];
    const held = createHeldTurns({ storage: memoryStorage(), key: 'k', deliver: async () => answers.shift() });
    held.hold({ samples: new Float32Array(4), error: 'upload failed' });
    held.hold({ text: 'next', state: 'waiting' });
    await held.drain();
    expect(held.list()).toMatchObject([{ text: 'next', state: 'failed', error: 'mode off' }]);
  });

  test('text-bearing turns survive a reload through storage; untranscribed ones cannot', async () => {
    const storage = memoryStorage();
    const key = heldStorageKey('chat-1');
    const first = createHeldTurns({ storage, key, deliver: async () => ({ ok: false }) });
    first.hold({ text: 'kept', signedId: 'sig', durationMs: 1200, error: 'offline' });
    first.hold({ samples: new Float32Array(4), durationMs: 900, error: 'upload failed' });
    expect(JSON.parse(storage.data[key])).toEqual([
      { text: 'kept', signedId: 'sig', durationMs: 1200, error: 'offline' },
    ]);

    const reloaded = createHeldTurns({ storage, key, deliver: async () => ({ ok: true }) });
    expect(reloaded.list()).toMatchObject([{ text: 'kept', state: 'failed', transcribed: true }]);
    await reloaded.drain({ auto: true });
    expect(reloaded.size).toBe(0);
    expect(storage.data[key]).toBeUndefined();
  });

  test('discarding the turn being sent removes it without resending', async () => {
    let finish;
    const held = createHeldTurns({
      storage: memoryStorage(),
      key: 'k',
      deliver: () => new Promise((resolve) => (finish = resolve)),
    });
    const id = held.hold({ text: 'gone' });
    const run = held.drain();
    held.discard(id);
    finish({ ok: false, error: 'late' });
    await run;
    expect(held.size).toBe(0);
  });
});
