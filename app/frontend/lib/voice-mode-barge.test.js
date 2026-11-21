import { describe, expect, test } from 'vitest';
import { createTurnDetector } from './voice-mode';

// Barge-in over a reply (YXDkBY), on synthetic signals only: the reply is a
// 220 Hz tone in words (240 ms on, 160 ms off), the person a 330 Hz tone, the
// room a little noise. What the microphone hears is the samples added
// together, not the larger of two envelopes. Leakage is the reply's own
// samples, scaled and 40 ms late. The player's level is the RMS of the reply
// samples at that moment, as voice-mode-playback reports it.

const RATE = 16_000;
const FRAME = RATE / 50; // 20 ms
const REPLY = 0.3; // the reply's peak amplitude
const REPLY_RMS = REPLY / Math.SQRT2;
// Mic leakage at the loudness change's two settings: about .035 RMS at x1 (the
// level in the #1071 review), x2.2 at the +7 dB setting.
const LEAK = { x1: 0.035 / REPLY_RMS, x2_2: (0.035 * 2.2) / REPLY_RMS };
const LAG = 2; // frames from speaker to mic

let wordOn = (ms) => ms % 400 < 240;

function tone(frameIndex, amplitude, freq) {
  const out = new Float32Array(FRAME);
  for (let i = 0; i < FRAME; i += 1) out[i] = amplitude * Math.sin((2 * Math.PI * freq * (frameIndex * FRAME + i)) / RATE);
  return out;
}

// A scene, frame by frame: replyFrom/replyTo in frames (playback), leak the
// coupling, person [{ from, to, level }] in frames, room the noise level.
function scene({ frames, replyFrom = Infinity, replyTo = Infinity, leak = 0, person = [], room = 0.001, replyLevel = REPLY }) {
  const out = [];
  const replyAt = (t) => {
    if (t < replyFrom || t >= replyTo) return null;
    const amplitude = wordOn((t - replyFrom) * 20) ? replyLevel : 0;
    return tone(t - replyFrom, amplitude, 220);
  };
  for (let t = 0; t < frames; t += 1) {
    const mic = tone(t, room, 50);
    const late = replyAt(t - LAG);
    if (late && leak) for (let i = 0; i < FRAME; i += 1) mic[i] += leak * late[i];
    for (const p of person) {
      if (t >= p.from && t < p.to) {
        const voice = tone(t, p.level * Math.SQRT2, 330);
        for (let i = 0; i < FRAME; i += 1) mic[i] += voice[i];
      }
    }
    const now = replyAt(t);
    let level = null;
    if (now) {
      let sum = 0;
      for (let i = 0; i < FRAME; i += 1) sum += now[i] * now[i];
      level = Math.sqrt(sum / FRAME);
    }
    out.push({ mic, sound: now ? { playing: true, level } : { playing: false, level: null } });
  }
  return out;
}

function run(detector, frames, { withoutLevel = false } = {}) {
  const events = [];
  frames.forEach(({ mic, sound }, t) => {
    const heard = withoutLevel && sound.playing ? { playing: true, level: null } : sound;
    for (const event of detector.feed(mic, heard)) events.push({ ...event, frame: t });
  });
  return events;
}

const detector = (options = {}) => createTurnDetector({ sampleRate: RATE, streamFrames: true, ...options });

describe('barge-in while a reply is heard', () => {
  for (const [name, leak] of Object.entries(LEAK)) {
    test(`leakage alone, from the first frame of the reply, never starts a turn (${name})`, () => {
      const events = run(detector(), scene({ frames: 600, replyFrom: 50, leak }));
      expect(events.filter((e) => e.type === 'start')).toEqual([]);
    });

    test(`a soft "wait" over the first word starts a turn and keeps that word (${name})`, () => {
      const onset = 50;
      const events = run(detector(), scene({ frames: 300, replyFrom: onset, leak, person: [{ from: onset, to: onset + 20, level: 0.04 }] }));
      const start = events.find((e) => e.type === 'start');
      expect(start?.barge).toBe(true);
      // Every frame from the reply's first onwards is in the turn.
      expect(start.samples.length / FRAME).toBeGreaterThanOrEqual(start.frame - onset + 1);
    });

    test(`a soft "wait" mid-reply starts a turn (${name})`, () => {
      const events = run(detector(), scene({ frames: 400, replyFrom: 0, leak, person: [{ from: 150, to: 170, level: 0.04 }] }));
      const starts = events.filter((e) => e.type === 'start');
      expect(starts).toHaveLength(1);
      expect(starts[0].frame).toBeGreaterThanOrEqual(150);
      expect(starts[0].frame).toBeLessThan(170);
    });
  }

  test('one reply\'s echo does not set the bar for the next (the #1071 review repro, quiet after the start)', () => {
    const frames = [
      ...scene({ frames: 50, replyFrom: 0, leak: LEAK.x1 }), // 1 s of a reply at .035 in the mic
      ...scene({ frames: 1500 }), // 30 s of quiet room
    ];
    // The next reply: perfectly cancelled for 520 ms, then 500 ms of a person at .04.
    const next = scene({ frames: 60, replyFrom: 0, leak: 0, person: [{ from: 26, to: 51, level: 0.04 }] });
    for (const withoutLevel of [false, true]) {
      const events = run(detector(), [...frames, ...next], { withoutLevel });
      const start = events.find((e) => e.type === 'start');
      expect(start, withoutLevel ? 'without a level' : 'with a level').toBeTruthy();
      expect(start.frame).toBeGreaterThanOrEqual(1550 + 26);
    }
  });

  test('a reply still being made or queued is not sound: a "wait" starts a turn on the ordinary attack', () => {
    const quiet = scene({ frames: 50 });
    const voice = scene({ frames: 10, person: [{ from: 0, to: 10, level: 0.04 }] });
    const events = run(detector(), [...quiet, ...voice]);
    const start = events.find((e) => e.type === 'start');
    expect(start.barge).toBe(false);
    expect(start.frame).toBe(50 + 2); // 60 ms
  });

  test('every playback start forgets the coupling, including after an underrun', () => {
    const d = detector();
    run(d, scene({ frames: 100, replyFrom: 0, leak: LEAK.x2_2 }));
    expect(d.coupling).toBeGreaterThan(0);
    // Buffering: the echo gate stays on through the lag window, then forgets.
    for (let t = 0; t < 6; t += 1) d.feed(tone(t, 0.001, 50), { playing: false, level: null });
    expect(d.coupling).toBe(0);
  });

  test('leakage loud enough to matter: with no sound signal it would start a turn (the control)', () => {
    const frames = scene({ frames: 600, replyFrom: 50, leak: LEAK.x1 }).map(({ mic }) => ({ mic, sound: { playing: false, level: null } }));
    expect(run(detector(), frames).some((e) => e.type === 'start')).toBe(true);
  });

  test('a long unbroken word: the reply\'s level holds it; energy alone (the audio element) does not', () => {
    const before = wordOn;
    wordOn = (ms) => ms < 700 || ms % 400 < 240; // the first word lasts 700 ms
    try {
      const frames = scene({ frames: 300, replyFrom: 50, leak: LEAK.x1 });
      expect(run(detector(), frames).some((e) => e.type === 'start')).toBe(false);
      // A known limit, kept visible: without the reply's samples, 300 ms of
      // leakage over the start bar at onset reads as a person.
      expect(run(detector(), frames, { withoutLevel: true }).some((e) => e.type === 'start')).toBe(true);
    } finally {
      wordOn = before;
    }
  });
});

// Frames marked by amplitude, so a turn's samples say which frames it holds.
function marked(index, loud) {
  const out = new Float32Array(FRAME);
  const amplitude = (loud ? 0.2 : 0.001) + index * 1e-6;
  for (let i = 0; i < FRAME; i += 1) out[i] = amplitude * (i % 2 === 0 ? 1 : -1);
  return out;
}

function marks(samples) {
  const out = [];
  for (let i = 0; i < samples.length; i += FRAME) {
    const a = Math.abs(samples[i]);
    out.push(Math.round(((a > 0.1 ? a - 0.2 : a - 0.001) * 1e6)));
  }
  return out;
}

describe('pre-roll with marked frames', () => {
  // 30 quiet frames, then a candidate with a gap: loud, quiet, then 20 loud.
  const pattern = [...Array(30).fill(false), true, false, ...Array(20).fill(true), ...Array(160).fill(false)];

  for (const preRollMs of [300, 0]) {
    for (const playing of [false, true]) {
      test(`preRollMs ${preRollMs}, ${playing ? 'over a reply in a pause' : 'nothing playing'}: the turn starts exactly at its pre-roll, in order, once`, () => {
        const d = detector({ preRollMs, streamFrames: false });
        // A reply in a pause between words: playing, at level 0.
        const sound = playing ? { playing: true, level: 0 } : { playing: false, level: null };
        const events = pattern.flatMap((loud, i) => d.feed(marked(i, loud), sound));
        const end = events.find((e) => e.type === 'end');
        const held = marks(end.samples);
        const preRoll = preRollMs / 20;
        // Nothing playing: the 60 ms attack needs three loud frames in a row, so
        // the gap ends the first attempt and the turn proves itself on 32-34.
        // Over a reply the candidate opens on frame 30 and keeps its gap.
        const first = playing ? 30 : 32;
        const expected = [];
        for (let i = first - preRoll; i < pattern.length && expected.length < held.length; i += 1) expected.push(i);
        expect(held.slice(0, preRoll + 1)).toEqual(expected.slice(0, preRoll + 1));
        expect(held).toEqual(expected);
      });
    }
  }
});

// As the panel does it: once a turn starts the reply pauses, so the mic hears
// no more of it and the player says nothing plays.
function runCutting(d, frames) {
  const events = [];
  let cut = false;
  frames.forEach(({ mic, person, sound }, t) => {
    const heard = cut ? { playing: false, level: null } : sound;
    for (const event of d.feed(cut ? person : mic, heard)) {
      events.push({ ...event, frame: t });
      if (event.type === 'start') cut = true;
    }
  });
  return events;
}

// The same scene, also keeping what the mic hears without the reply.
function sceneWithPerson(options) {
  const withReply = scene(options);
  const alone = scene({ ...options, leak: 0 });
  return withReply.map((f, t) => ({ ...f, person: alone[t].mic }));
}

describe('a barge-in that is a person reaches a turn, with its first word (#1081 review)', () => {
  for (const [name, leak] of Object.entries(LEAK)) {
    for (const [where, from, replyFrom] of [['at onset', 50, 50], ['mid-reply', 150, 0]]) {
      test(`a 360 ms soft "wait" ${where} is an accepted turn, not a discard (${name})`, () => {
        const frames = sceneWithPerson({ frames: from + 18 + 200, replyFrom, leak, person: [{ from, to: from + 18, level: 0.04 }] });
        const events = runCutting(detector(), frames);
        expect(events.map((e) => e.type)).toEqual(['start', ...Array(events.length - 1).fill('audio').slice(0, events.length - 2), 'end']);
        const start = events[0];
        // The turn holds every frame of the word from its first.
        expect(start.samples.length / FRAME).toBeGreaterThanOrEqual(start.frame - from + 1);
      });
    }

    test(`a 60 ms cough in a gap between the reply's words is still discarded (${name})`, () => {
      // Word gaps are 240–400 ms into each 400 ms; the cough at 3.10–3.16 s, in one.
      const frames = sceneWithPerson({ frames: 400, replyFrom: 0, leak, person: [{ from: 155, to: 158, level: 0.1 }] });
      const events = runCutting(detector(), frames);
      expect(events.some((e) => e.type === 'end')).toBe(false);
    });
  }
});

describe('the echo tail when the sound stops (#1081 review)', () => {
  // One second of mic leakage at .077 against a reply at .2, all at once.
  const leaking = (t) => ({ mic: tone(t, 0.077 * Math.SQRT2, 220), sound: { playing: true, level: 0.2 } });
  const quiet = (t, extra = 0) => ({ mic: tone(t, 0.077 * Math.SQRT2, 220), sound: { playing: false, level: null }, extra });

  test('the reply\'s last frames in the mic after it stops are not a person', () => {
    const frames = [...Array.from({ length: 50 }, (_, t) => leaking(t)), ...Array.from({ length: 3 }, (_, t) => quiet(50 + t))];
    // then the room is quiet
    for (let t = 53; t < 200; t += 1) frames.push({ mic: tone(t, 0.001, 50), sound: { playing: false, level: null } });
    expect(run(detector(), frames).some((e) => e.type === 'start')).toBe(false);
  });

  test('a real word at that boundary still starts a turn and keeps its beginning', () => {
    const frames = [...Array.from({ length: 50 }, (_, t) => leaking(t))];
    for (let t = 50; t < 70; t += 1) {
      const mic = tone(t, 0.06 * Math.SQRT2, 330);
      if (t < 53) {
        const echo = tone(t, 0.077 * Math.SQRT2, 220);
        for (let i = 0; i < FRAME; i += 1) mic[i] += echo[i];
      }
      frames.push({ mic, sound: { playing: false, level: null } });
    }
    for (let t = 70; t < 250; t += 1) frames.push({ mic: tone(t, 0.001, 50), sound: { playing: false, level: null } });
    const events = run(detector(), frames);
    const start = events.find((e) => e.type === 'start');
    expect(start).toBeTruthy();
    expect(start.samples.length / FRAME).toBeGreaterThanOrEqual(start.frame - 50 + 1);
    expect(events.some((e) => e.type === 'end')).toBe(true);
  });
});
