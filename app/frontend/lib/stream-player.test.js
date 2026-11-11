import { get } from 'svelte/store';
import { beforeEach, expect, test, vi } from 'vitest';
import { createStreamPlayer, LEAD } from './stream-player';

// A Web Audio context with a clock the test moves, and every scheduled
// source kept so the test can see where it starts and end it.
function fakeContext() {
  const ctx = {
    currentTime: 0,
    state: 'running',
    nodes: [],
    destination: {},
    resume: vi.fn(() => Promise.resolve()),
    suspend: vi.fn(() => Promise.resolve()),
    close: vi.fn(() => {
      ctx.state = 'closed';
      return Promise.resolve();
    }),
    createBuffer: (channels, length, rate) => {
      const data = new Float32Array(length);
      return { duration: length / rate, getChannelData: () => data, data };
    },
    createBufferSource: () => {
      const node = {
        connect: vi.fn(),
        start: vi.fn((at) => (node.at = at)),
        stop: vi.fn(() => (node.stopped = true)),
        onended: null,
      };
      ctx.nodes.push(node);
      return node;
    },
  };
  return ctx;
}

const RATE = 10; // ten samples a second keeps the arithmetic readable
const chunk = (n, value = 0.5) => new Float32Array(n).fill(value);
let ctx;
let ended;
let player;

beforeEach(() => {
  ctx = fakeContext();
  ended = vi.fn();
  player = createStreamPlayer({ context: () => ctx, onended: ended });
});

test('the first chunk sounds as soon as it is made, and the next ones play straight after it, in order', () => {
  ctx.currentTime = 1;
  player.push(chunk(10), RATE);
  player.push(chunk(5), RATE);
  player.push(chunk(20), RATE);
  expect(ctx.nodes.map((n) => n.at)).toEqual([1 + LEAD, 2 + LEAD, 2.5 + LEAD]);
  expect(ctx.nodes.map((n) => n.buffer.data.length)).toEqual([10, 5, 20]);
  expect(get(player.state)).toMatchObject({ playing: true, duration: 3.5, done: false });
});

test('a chunk made after the one before has finished starts a little ahead, and the gap is not counted as heard', () => {
  player.push(chunk(10), RATE); // 0.08 → 1.08
  ctx.currentTime = 2; // the device fell behind: nothing played from 1.08 to 2
  player.push(chunk(10), RATE);
  expect(ctx.nodes[1].at).toBeCloseTo(2 + LEAD);
  ctx.currentTime = 2 + LEAD + 0.5;
  expect(player.position).toBeCloseTo(1.5);
});

test('it ends only when everything is made and heard, then releases its context', () => {
  player.push(chunk(10), RATE);
  ctx.nodes[0].onended();
  expect(ended).not.toHaveBeenCalled(); // still being made: a gap, not the end
  player.push(chunk(10), RATE);
  player.finish();
  expect(ended).not.toHaveBeenCalled();
  ctx.nodes[1].onended();
  expect(ended).toHaveBeenCalledTimes(1);
  expect(get(player.state)).toMatchObject({ ended: true, playing: false, position: 2 });
  expect(ctx.close).toHaveBeenCalled();
});

test('pause and play hold the clock, without stopping what is being made', () => {
  player.push(chunk(10), RATE);
  player.pause();
  expect(ctx.suspend).toHaveBeenCalled();
  expect(get(player.state).playing).toBe(false);
  player.push(chunk(10), RATE); // still accepted while paused
  expect(get(player.state).duration).toBe(2);
  player.play();
  expect(get(player.state).playing).toBe(true);
});

test('seeking waits until everything is made, then plays the joined chunks from there', () => {
  player.push(chunk(10, 0.1), RATE);
  player.push(chunk(10, 0.2), RATE);
  expect(player.seek(1.5)).toBe(false);
  player.finish();
  ctx.currentTime = 0.5;
  expect(player.seek(1.5)).toBe(true);
  expect(ctx.nodes[0].stopped && ctx.nodes[1].stopped).toBe(true);
  const fresh = ctx.nodes[2];
  expect(fresh.at).toBeCloseTo(0.5 + LEAD);
  expect(Array.from(fresh.buffer.data)).toEqual(Array(5).fill(0.2).map(Math.fround));
  ctx.currentTime = 0.5 + LEAD + 0.2;
  expect(player.position).toBeCloseTo(1.7);
  // the stopped sources ending late do not end the new run
  ctx.nodes[0].onended?.();
  expect(ended).not.toHaveBeenCalled();
  fresh.onended();
  expect(ended).toHaveBeenCalledTimes(1);
});

test('stop silences it, closes the context, and nothing pushed afterwards plays', () => {
  player.push(chunk(10), RATE);
  player.stop();
  expect(ctx.nodes[0].stopped).toBe(true);
  expect(ctx.close).toHaveBeenCalled();
  player.push(chunk(10), RATE);
  player.finish();
  expect(ctx.nodes).toHaveLength(1);
  expect(ended).not.toHaveBeenCalled();
});

test('a chunk is copied, so a buffer the engine reuses cannot change what is heard', () => {
  const reused = chunk(4, 0.3);
  player.push(reused, RATE);
  reused.fill(0.9);
  expect(Array.from(ctx.nodes[0].buffer.data)).toEqual(Array(4).fill(Math.fround(0.3)));
});
