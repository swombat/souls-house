import { expect, test, vi } from 'vitest';
import { createPlayer, silentWav, unlockAudio } from './voice-mode-playback';

// A stand-in for the one <audio> element: records what it was asked to play
// and lets the test end a clip or refuse a play().
function fakeAudio() {
  const audio = new EventTarget();
  audio.log = [];
  audio.refuse = false;
  audio.pending = null;
  audio.play = vi.fn(() => {
    audio.log.push(['play', audio.src]);
    if (audio.hold) return new Promise((_, reject) => (audio.pending = reject));
    return audio.refuse ? Promise.reject(new Error('NotAllowedError')) : Promise.resolve();
  });
  audio.pause = vi.fn(() => audio.log.push(['pause']));
  audio.load = vi.fn();
  audio.removeAttribute = vi.fn(() => (audio.src = ''));
  audio.end = () => audio.dispatchEvent(new Event('ended'));
  return audio;
}
const urlFor = (id) => `/messages/${id}/speech`;

test('the silent unlock clip is a well-formed 8-bit mono WAV of silence', () => {
  const uri = silentWav(10);
  const bytes = Uint8Array.from(atob(uri.split(',')[1]), (c) => c.charCodeAt(0));
  const ascii = (from, to) => String.fromCharCode(...bytes.slice(from, to));
  expect(uri.startsWith('data:audio/wav;base64,')).toBe(true);
  expect([ascii(0, 4), ascii(8, 16), ascii(36, 40)]).toEqual(['RIFF', 'WAVEfmt ', 'data']);
  expect(bytes.length).toBe(54);
  expect([...bytes.slice(44)]).toEqual(Array(10).fill(128));
});

test('unlocking starts the shared element on the silent clip inside the tap', () => {
  const audio = fakeAudio();
  unlockAudio(audio);
  expect(audio.play).toHaveBeenCalledTimes(1);
  expect(audio.src).toMatch(/^data:audio\/wav;base64,/);
});

test('replies play one at a time, in order, each when the one before ends', () => {
  const audio = fakeAudio();
  const changes = [];
  const player = createPlayer({ audio, urlFor, onchange: (id) => changes.push(id) });
  player.enqueue('a');
  player.enqueue('b');
  expect(audio.log).toEqual([['play', '/messages/a/speech']]);
  audio.end();
  expect(audio.log.at(-1)).toEqual(['play', '/messages/b/speech']);
  audio.end();
  expect(player.speaking).toBe(false);
  expect(changes).toEqual(['a', 'b', null]);
});

test('interrupting stops what is playing and drops the queue; the next reply plays normally', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  player.enqueue('b');
  player.interrupt();
  expect(audio.pause).toHaveBeenCalled();
  expect(player.speaking).toBe(false);
  audio.end(); // a stray ended from the stopped clip
  expect(audio.log.filter(([kind]) => kind === 'play')).toHaveLength(1);
  player.enqueue('c');
  expect(audio.log.at(-1)).toEqual(['play', '/messages/c/speech']);
});

test('a play() refused before an interrupt moves on; one settling after it changes nothing', async () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  audio.refuse = true;
  player.enqueue('a');
  audio.refuse = false;
  player.enqueue('b');
  await Promise.resolve();
  await Promise.resolve();
  expect(audio.log.at(-1)).toEqual(['play', '/messages/b/speech']);

  audio.hold = true;
  audio.end(); // b ends
  player.enqueue('c');
  const rejectC = audio.pending;
  player.interrupt();
  player.enqueue('d');
  rejectC(new Error('AbortError')); // c's play() settles late, after the interrupt
  await Promise.resolve();
  await Promise.resolve();
  expect(audio.log.filter(([kind]) => kind === 'play').map(([, src]) => src)).toEqual([
    '/messages/a/speech',
    '/messages/b/speech',
    '/messages/c/speech',
    '/messages/d/speech',
  ]);
  expect(player.speaking).toBe(true);
});

test('closing stops playback and stops listening to the shared element', () => {
  const audio = fakeAudio();
  const changes = [];
  const player = createPlayer({ audio, urlFor, onchange: (id) => changes.push(id) });
  player.enqueue('a');
  player.close();
  audio.end();
  expect(changes).toEqual(['a', null]);
});

test('a closed player accepts nothing more: no reply starts after End', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.close();
  player.enqueue('late');
  expect(audio.play).not.toHaveBeenCalled();
  expect(player.speaking).toBe(false);
});

test('interrupting returns what it dropped: the playing reply, then the queue', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  expect(player.interrupt()).toEqual([]);
  player.enqueue('a');
  player.enqueue('b');
  player.enqueue('c');
  audio.currentTime = 7.5;
  expect(player.interrupt()).toEqual([
    { id: 'a', at: 7.5, playing: true },
    { id: 'b', at: 0, playing: false },
    { id: 'c', at: 0, playing: false },
  ]);
  expect(player.interrupt()).toEqual([]);
});

test('an interrupted reply is parked, not torn down: a resume plays on from the same position on the same audio (#758)', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  audio.currentTime = 12;
  expect(player.interrupt()).toEqual([{ id: 'a', at: 12, playing: true }]);
  expect(audio.src).toBe('/messages/a/speech');
  expect(audio.log.at(-1)).toEqual(['pause']);
  player.enqueue('a', { resume: true });
  // No new request: the same source plays on, from where it paused.
  expect(audio.log.at(-1)).toEqual(['play', '/messages/a/speech']);
  expect(audio.currentTime).toBe(12);
  // Interrupted again later: the real position, not an estimate.
  audio.currentTime = 19;
  expect(player.interrupt()).toEqual([{ id: 'a', at: 19, playing: true }]);
  player.enqueue('a', { resume: true });
  audio.end();
  expect(player.speaking).toBe(false);
  expect(audio.log.filter(([kind]) => kind === 'play')).toHaveLength(3);
});

test('a restart, or a resume of anything but the parked reply, is a fresh request from the top', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  audio.currentTime = 2;
  player.interrupt();
  audio.src = '/messages/a/speech';
  player.enqueue('a');
  expect(audio.log.at(-1)).toEqual(['play', '/messages/a/speech']);
  player.interrupt();
  player.enqueue('b', { resume: true });
  expect(audio.log.at(-1)).toEqual(['play', '/messages/b/speech']);
  audio.end();
  player.enqueue('a', { resume: true });
  expect(audio.log.at(-1)).toEqual(['play', '/messages/a/speech']);
});

test('a resumed reply whose parked stream died is asked for again from the top, never skipped', async () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  audio.currentTime = 30;
  player.interrupt();
  audio.src = 'stale';
  audio.refuse = true;
  player.enqueue('a', { resume: true });
  audio.refuse = false;
  await Promise.resolve();
  await Promise.resolve();
  expect(audio.log.at(-1)).toEqual(['play', '/messages/a/speech']);
  expect(player.speaking).toBe(true);
});

test('End drops a parked reply: nothing resumes after close', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  audio.currentTime = 9;
  player.interrupt();
  player.close();
  expect(audio.src).toBe('');
  player.enqueue('a', { resume: true });
  expect(audio.log.filter(([kind]) => kind === 'play')).toHaveLength(1);
});

test('an error while the reply is parked forgets it: the resume is a fresh request (Mira, round 2)', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  audio.currentTime = 30;
  player.interrupt();
  audio.src = 'stale';
  audio.dispatchEvent(new Event('error'));
  player.enqueue('a', { resume: true });
  expect(audio.log.at(-1)).toEqual(['play', '/messages/a/speech']);
});

test('a parked element already in error is not resumed, even if its error event was missed', () => {
  const audio = fakeAudio();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  audio.currentTime = 30;
  player.interrupt();
  audio.src = 'stale';
  audio.error = { code: 2 };
  player.enqueue('a', { resume: true });
  expect(audio.log.at(-1)).toEqual(['play', '/messages/a/speech']);
});

// Phonon makes the audio before it can play, so urlFor answers with a promise.
// Each request is kept here with its signal and its own resolve/reject.
function deferredSource() {
  const requests = [];
  const urlFor = vi.fn((id, { signal } = {}) => {
    let resolve, reject;
    const promise = new Promise((ok, fail) => ((resolve = ok), (reject = fail)));
    requests.push({ id, signal, resolve, reject });
    return promise;
  });
  return { urlFor, requests };
}
const flush = async () => {
  for (let i = 0; i < 5; i += 1) await Promise.resolve();
};

test('a reply still being made plays nothing until its audio is ready', async () => {
  const audio = fakeAudio();
  const { urlFor, requests } = deferredSource();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  expect(player.speaking).toBe(true);
  await flush();
  expect(audio.play).not.toHaveBeenCalled();
  requests[0].resolve('blob:a');
  await flush();
  expect(audio.log).toEqual([['play', 'blob:a']]);
});

test('interrupting a reply still being made aborts the making, parks nothing, and ignores its late audio', async () => {
  const audio = fakeAudio();
  const { urlFor, requests } = deferredSource();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  audio.currentTime = 4; // left over from an earlier clip: not this reply's position
  expect(player.interrupt()).toEqual([{ id: 'a', at: 0, playing: false }]);
  expect(requests[0].signal.aborted).toBe(true);
  expect(audio.pause).not.toHaveBeenCalled();

  requests[0].resolve('blob:a');
  await flush();
  expect(audio.src).toBeUndefined();
  expect(audio.play).not.toHaveBeenCalled();

  // It was never parked, so a resume asks for it again.
  player.enqueue('a', { resume: true });
  expect(requests).toHaveLength(2);
  expect(requests[1].id).toBe('a');
  requests[1].resolve('blob:a2');
  await flush();
  expect(audio.log).toEqual([['play', 'blob:a2']]);
});

test('a reply that cannot be made is reported and the next one plays', async () => {
  const audio = fakeAudio();
  const onerror = vi.fn();
  const { urlFor, requests } = deferredSource();
  const player = createPlayer({ audio, urlFor, onerror });
  player.enqueue('a');
  player.enqueue('b');
  const failure = new Error('Phonon needs WebGPU.');
  requests[0].reject(failure);
  await flush();
  expect(onerror).toHaveBeenCalledWith('a', failure);
  expect(requests[1].id).toBe('b');
  requests[1].resolve('blob:b');
  await flush();
  expect(audio.log).toEqual([['play', 'blob:b']]);
});

test('an aborted making is not reported as a failure', async () => {
  const audio = fakeAudio();
  const onerror = vi.fn();
  const { urlFor, requests } = deferredSource();
  const player = createPlayer({ audio, urlFor, onerror });
  player.enqueue('a');
  player.enqueue('b');
  requests[0].reject(Object.assign(new Error('aborted'), { name: 'AbortError' }));
  await flush();
  expect(onerror).not.toHaveBeenCalled();
  expect(requests.map(({ id }) => id)).toEqual(['a', 'b']);
});

test('closing while a reply is being made means it never plays', async () => {
  const audio = fakeAudio();
  const { urlFor, requests } = deferredSource();
  const player = createPlayer({ audio, urlFor });
  player.enqueue('a');
  player.close();
  expect(requests[0].signal.aborted).toBe(true);
  requests[0].resolve('blob:a');
  await flush();
  expect(audio.play).not.toHaveBeenCalled();
  expect(player.speaking).toBe(false);
});
