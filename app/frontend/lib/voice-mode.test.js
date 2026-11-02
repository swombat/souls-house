import { describe, expect, test } from 'vitest';
import { createTurnDetector, downsample, encodeWav, encodeWavBytes, stripReleasePhrase } from './voice-mode';

const RATE = 16_000;
const FRAME = RATE / 50; // 20 ms

function frames(count, amplitude) {
  const out = new Float32Array(count * FRAME);
  for (let i = 0; i < out.length; i += 1) out[i] = amplitude * (i % 2 === 0 ? 1 : -1);
  return out;
}

function feedAll(detector, chunks) {
  return chunks.flatMap((chunk) => detector.feed(chunk));
}

describe('createTurnDetector', () => {
  test('an utterance ends after the silence interval and carries its pre-roll', () => {
    const detector = createTurnDetector({ sampleRate: RATE, silenceMs: 1000, preRollMs: 300, minSpeechMs: 300 });
    const events = feedAll(detector, [
      frames(50, 0.002), // a second of quiet room
      frames(40, 0.2), // 800 ms of speech
      frames(49, 0.002), // 980 ms of silence: not yet
    ]);
    expect(events.map((e) => e.type)).toEqual(['start']);

    const [end] = detector.feed(frames(1, 0.002));
    expect(end.type).toBe('end');
    // The 300 ms pre-roll (15 frames) ends with the 3 attack frames that proved
    // speech, then the remaining 37 frames of speech, then 1000 ms of silence.
    expect(end.samples.length).toBe((15 + 37 + 50) * FRAME);
    expect(end.durationMs).toBe(2040);
    expect(detector.speaking).toBe(false);
  });

  test('a short burst is discarded rather than sent', () => {
    const detector = createTurnDetector({ sampleRate: RATE, silenceMs: 600, minSpeechMs: 300 });
    const events = feedAll(detector, [frames(25, 0.002), frames(6, 0.3), frames(31, 0.002)]);
    expect(events.map((e) => e.type)).toEqual(['start', 'discard']);
  });

  test('a loud room raises the threshold instead of starting a turn', () => {
    const detector = createTurnDetector({ sampleRate: RATE, floor: 0.012, noiseRatio: 3 });
    const events = feedAll(detector, [frames(200, 0.03)]);
    expect(events).toEqual([]);
    expect(detector.threshold).toBeGreaterThan(0.08);
    // Speech well above the room still starts.
    expect(detector.feed(frames(5, 0.5)).map((e) => e.type)).toEqual(['start']);
  });

  test('flush ends the utterance in progress and is quiet otherwise', () => {
    const detector = createTurnDetector({ sampleRate: RATE });
    expect(detector.flush()).toEqual([]);
    feedAll(detector, [frames(10, 0.002), frames(30, 0.3)]);
    const [end] = detector.flush();
    expect(end.type).toBe('end');
    expect(detector.flush()).toEqual([]);
  });

  test('chunks of any size are reassembled into frames', () => {
    const a = createTurnDetector({ sampleRate: RATE, silenceMs: 400 });
    const b = createTurnDetector({ sampleRate: RATE, silenceMs: 400 });
    const signal = new Float32Array([...frames(10, 0.002), ...frames(30, 0.3), ...frames(25, 0.002)]);
    const whole = a.feed(signal);
    const pieces = [];
    for (let i = 0; i < signal.length; i += 777) pieces.push(...b.feed(signal.subarray(i, i + 777)));
    expect(pieces.map((e) => e.type)).toEqual(whole.map((e) => e.type));
    expect(pieces.at(-1).samples.length).toBe(whole.at(-1).samples.length);
  });
});

describe('downsample and encodeWav', () => {
  test('downsample keeps the duration and lowers the rate', () => {
    const samples = new Float32Array(48_000).map((_, i) => Math.sin(i / 20));
    const out = downsample(samples, 48_000, 16_000);
    expect(out.length).toBe(16_000);
    expect(() => downsample(out, 16_000, 48_000)).toThrow();
    expect(downsample(out, 16_000, 16_000)).toBe(out);
  });

  test('encodeWav writes a 16-bit mono header and clamps samples', () => {
    const samples = new Float32Array([0, 0.5, -0.5, 2, -2]);
    expect(encodeWav(samples, 16_000).type).toBe('audio/wav');
    const view = new DataView(encodeWavBytes(samples, 16_000));
    expect(String.fromCharCode(...new Uint8Array(view.buffer, 0, 4))).toBe('RIFF');
    expect(view.getUint16(22, true)).toBe(1); // channels
    expect(view.getUint32(24, true)).toBe(16_000);
    expect(view.getUint16(34, true)).toBe(16);
    expect(view.getUint32(40, true)).toBe(10);
    expect(view.getInt16(44, true)).toBe(0);
    expect(view.getInt16(46, true)).toBe(Math.round(0.5 * 0x7fff));
    expect(view.getInt16(50, true)).toBe(0x7fff);
    expect(view.getInt16(52, true)).toBe(-0x8000);
  });
});

describe('stripReleasePhrase', () => {
  test('removes a trailing hand-over and says so', () => {
    expect(stripReleasePhrase('What is on today? Over to you.')).toEqual({ text: 'What is on today?', release: true });
    expect(stripReleasePhrase('what do you both think, over to you')).toEqual({
      text: 'what do you both think',
      release: true,
    });
  });

  test('leaves the phrase alone in the middle and ordinary text untouched', () => {
    expect(stripReleasePhrase('I handed it over to you yesterday, remember?')).toEqual({
      text: 'I handed it over to you yesterday, remember?',
      release: false,
    });
    expect(stripReleasePhrase('  plain  ')).toEqual({ text: 'plain', release: false });
    expect(stripReleasePhrase(null)).toEqual({ text: '', release: false });
  });
});
