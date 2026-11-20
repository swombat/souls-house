import { afterEach, beforeEach, expect, test, vi } from 'vitest';

// The reply side end to end under Phonon (JOyaQe): the reader, the real player
// and the real stream player on a fake Web Audio clock. In a phone test on
// 20 Nov (YnwyBe) a reply cut off by the panel's own detector seemed to come
// back only when Listen was pressed. These cover the paths by which a cut-off
// reply comes back by itself, discarded or sent, played on or from the top,
// made already or still being made. They establish those paths, not what
// happened on the phone.

// A Web Audio context whose clock moves only when the test says. Buffer
// sources end when the clock passes them, and only while it runs.
class FakeContext {
  state = 'running';
  currentTime = 0;
  destination = {};
  nodes = [];
  suspend() {
    this.state = 'suspended';
    return Promise.resolve();
  }
  resume() {
    this.state = 'running';
    return Promise.resolve();
  }
  close() {
    this.state = 'closed';
    return Promise.resolve();
  }
  createBuffer(_channels, length, rate) {
    const data = new Float32Array(length);
    return { duration: length / rate, getChannelData: () => data };
  }
  createBufferSource() {
    const node = { connect() {}, start: (at) => (node.at = at), stop: () => (node.stopped = true), onended: null };
    this.nodes.push(node);
    return node;
  }
  advance(seconds) {
    if (this.state !== 'running') return;
    this.currentTime += seconds;
    for (const node of this.nodes) {
      if (node.done || node.stopped || node.at + node.buffer.duration > this.currentTime) continue;
      node.done = true;
      node.onended?.();
    }
  }
  // How many scheduled buffers have not been heard yet.
  get pending() {
    return this.nodes.filter((n) => !n.done && !n.stopped).length;
  }
}

function fakeAudio() {
  const audio = new EventTarget();
  audio.log = [];
  audio.play = vi.fn(() => {
    audio.log.push(['play', audio.src]);
    return Promise.resolve();
  });
  audio.pause = vi.fn(() => audio.log.push(['pause']));
  audio.load = vi.fn();
  audio.removeAttribute = vi.fn(() => (audio.src = ''));
  audio.end = () => audio.dispatchEvent(new Event('ended'));
  return audio;
}

// The speech source as Phonon answers: chunks while a reply is made, then its
// kept WAV; a reply already made resolves at once and sends no chunks.
function fakeSource() {
  const made = new Map();
  const making = {};
  const asked = [];
  return {
    made,
    making,
    asked,
    resolve(id, { signal, onAudio } = {}) {
      asked.push(id);
      if (made.has(id)) return Promise.resolve({ url: made.get(id), engine: 'phonon' });
      return new Promise((resolve, reject) => {
        making[id] = {
          chunk: (seconds) => onAudio?.(new Float32Array(Math.round(seconds * 24000)), 24000),
          done: () => {
            made.set(id, `blob:${id}`);
            resolve({ url: `blob:${id}`, engine: 'phonon' });
          },
          signal,
        };
        signal?.addEventListener('abort', () => reject(Object.assign(new Error('aborted'), { name: 'AbortError' })));
      });
    },
    close() {},
  };
}

const message = (id) => ({
  id,
  role: 'assistant',
  voice_available: true,
  completed: true,
  content: 'Spoken.',
  created_at: '2026-11-20T15:20:00Z',
});
const opened = [{ id: 'before', role: 'user', content: 'Hi', created_at: '2026-11-20T15:19:00Z' }];
const flush = async () => {
  for (let i = 0; i < 6; i += 1) await Promise.resolve();
};

let ctx;
let createReplyReader;
let playing;
beforeEach(async () => {
  vi.resetModules();
  ctx = new FakeContext();
  vi.stubGlobal('AudioContext', function () {
    return ctx;
  });
  ({ createReplyReader } = await import('./voice-mode-reader'));
});
afterEach(() => vi.unstubAllGlobals());

function setup() {
  const audio = fakeAudio();
  const source = fakeSource();
  playing = null;
  const reader = createReplyReader({ messages: opened, source, audio, onchange: (id) => (playing = id) });
  const messages = [...opened, message('r')];
  reader.take(messages);
  return { audio, source, reader, messages };
}

test('cut off after 5 s while still being made, then discarded: it plays on from where it was, not made again', async () => {
  const { source, reader, messages } = setup();
  source.making.r.chunk(8);
  ctx.advance(6);
  reader.speechStarted();
  expect(ctx.state).toBe('suspended');
  source.making.r.chunk(4); // made on while parked
  reader.discarded(messages);
  expect(ctx.state).toBe('running');
  expect(playing).toBe('r');
  expect(source.asked).toEqual(['r']);
});

test('cut off after 5 s, finished being made while parked, then discarded: it plays on and the queue moves after it', async () => {
  const { source, reader, messages } = setup();
  source.making.r.chunk(8);
  ctx.advance(6);
  reader.speechStarted();
  source.making.r.chunk(4);
  source.making.r.done();
  await flush();
  reader.discarded(messages);
  expect(ctx.state).toBe('running');
  expect(playing).toBe('r');
  ctx.advance(7);
  expect(playing).toBe(null); // heard to the end
  expect(source.asked).toEqual(['r']);
});

test('cut off under 5 s while still being made: made again from the top, and heard on the context it parked', async () => {
  const { source, reader, messages } = setup();
  const first = source.making.r;
  first.chunk(8);
  ctx.advance(2);
  reader.speechStarted();
  reader.discarded(messages);
  expect(first.signal.aborted).toBe(true);
  expect(source.asked).toEqual(['r', 'r']);
  source.making.r.chunk(1);
  expect(ctx.state).toBe('running');
  expect(ctx.pending).toBeGreaterThan(0);
  expect(playing).toBe('r');
});

test('cut off under 5 s after it was all made: the kept WAV plays from the top through the element', async () => {
  const { audio, source, reader, messages } = setup();
  source.making.r.chunk(3);
  source.making.r.done();
  await flush();
  ctx.advance(2);
  reader.speechStarted();
  reader.discarded(messages);
  await flush();
  expect(audio.log).toContainEqual(['play', 'blob:r']);
  expect(playing).toBe('r');
});

test('a sent turn brings the cut-off reply back too (Daniel, #758)', async () => {
  const { source, reader, messages } = setup();
  source.making.r.chunk(8);
  ctx.advance(6);
  reader.speechStarted();
  reader.committed(messages);
  expect(ctx.state).toBe('running');
  expect(playing).toBe('r');
});

test('every cut-off brings it back, so a reply whose own echo keeps cutting it off loops and never finishes', async () => {
  const { source, reader, messages } = setup();
  source.making.r.chunk(3);
  source.making.r.done();
  await flush();
  // Its own echo starts a turn a second in, each time it is heard from the top.
  for (let round = 0; round < 4; round += 1) {
    ctx.advance(1);
    reader.speechStarted();
    reader.discarded(messages);
    await flush();
    expect(playing).toBe('r');
  }
  // It never reaches its end. One possible reading of 20 Nov, not a proven
  // one: that session left no trace of its starts. The trace now records them.
});
