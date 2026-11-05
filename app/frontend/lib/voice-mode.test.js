import { describe, expect, test } from 'vitest';
import {
  createTurnDetector,
  downsample,
  encodeWav,
  encodeWavBytes,
  pcm16Base64,
  resample,
  stripReleasePhrase,
  voiceModeStatus,
} from './voice-mode';

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

describe('streaming frames for the realtime transcriber', () => {
  test('start carries the pre-roll and each later frame of the turn arrives as audio', () => {
    const detector = createTurnDetector({ sampleRate: RATE, silenceMs: 200, preRollMs: 100, streamFrames: true });
    const events = feedAll(detector, [frames(10, 0.002), frames(20, 0.2), frames(10, 0.002)]);
    const [start, ...rest] = events;
    expect(start.type).toBe('start');
    // 100 ms of pre-roll is 5 frames, ending with the 3 attack frames.
    expect(start.samples.length).toBe(5 * FRAME);
    const audio = rest.filter((e) => e.type === 'audio');
    // 17 more frames of speech, then 10 of silence (the turn ends on the 10th).
    expect(audio).toHaveLength(17 + 10);
    expect(audio.every((e) => e.samples.length === FRAME)).toBe(true);
    expect(rest.at(-1).type).toBe('end');
  });

  test('without streamFrames the events are as before', () => {
    const detector = createTurnDetector({ sampleRate: RATE, silenceMs: 200 });
    const events = feedAll(detector, [frames(10, 0.002), frames(20, 0.2), frames(10, 0.002)]);
    expect(events.map((e) => e.type)).toEqual(['start', 'end']);
    expect(events[0]).toEqual({ type: 'start' });
  });
});

describe('resample', () => {
  test('halves 48 kHz to 24 kHz and doubles 12 kHz to 24 kHz', () => {
    expect(resample(new Float32Array(960), 48_000, 24_000)).toHaveLength(480);
    expect(resample(new Float32Array(240), 12_000, 24_000)).toHaveLength(480);
    expect(resample(new Float32Array([0.5]), 24_000, 24_000)).toEqual(new Float32Array([0.5]));
  });
});

describe('pcm16Base64', () => {
  test('little-endian 16-bit samples, clamped', () => {
    const bytes = Uint8Array.from(atob(pcm16Base64(new Float32Array([0, 1, -1, 2]))), (c) => c.charCodeAt(0));
    const view = new DataView(bytes.buffer);
    expect([0, 1, 2, 3].map((i) => view.getInt16(i * 2, true))).toEqual([0, 32767, -32768, 32767]);
  });
});

describe('voiceModeStatus', () => {
  const base = { phase: 'listening', muted: false, note: '', speaking: null };

  test('idle says the room is the person\'s to speak again, not "Listening" (Daniel, jNwAdJ eBVREL)', () => {
    expect(voiceModeStatus(base)).toBe('Waiting for you. Speak again to say something else.');
    expect(voiceModeStatus({ ...base, phase: 'hearing' })).toBe('Hearing you…');
  });

  test('a pause outranks every phase but starting and failed, and says why (jMapOj)', () => {
    expect(voiceModeStatus({ ...base, phase: 'sending', paused: 'hidden' })).toMatch(/^Paused: the screen went off/);
    expect(voiceModeStatus({ ...base, paused: 'muted' })).toMatch(/^Paused: the system took the microphone/);
    expect(voiceModeStatus({ ...base, paused: 'suspended', muted: true })).toMatch(
      /^Paused: the browser stopped the audio/
    );
    expect(voiceModeStatus({ ...base, phase: 'starting', paused: 'hidden' })).toBe('Opening the microphone…');
    expect(voiceModeStatus({ ...base, phase: 'failed', note: 'No mic', paused: 'hidden' })).toBe('No mic');
  });
});
