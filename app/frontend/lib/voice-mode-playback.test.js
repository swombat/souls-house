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
  expect(player.interrupt()).toEqual(['a', 'b', 'c']);
  expect(player.interrupt()).toEqual([]);
});
