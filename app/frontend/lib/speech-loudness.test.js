import { expect, test } from 'vitest';
import { CEILING, KNEE, SPEECH_GAIN_DB, louden, shapeSample } from './speech-loudness';

const gain = 10 ** (SPEECH_GAIN_DB / 20);

test('quiet samples are only scaled by the gain', () => {
  const out = louden(new Float32Array([0.1, -0.2, 0]));
  expect(out[0]).toBeCloseTo(0.1 * gain, 5);
  expect(out[1]).toBeCloseTo(-0.2 * gain, 5);
  expect(out[2]).toBe(0);
});

test('loud samples bend towards the ceiling and never clip, on both sides', () => {
  for (const value of [0.4, 0.6, 1, 4]) {
    const up = shapeSample(value, gain);
    expect(up).toBeGreaterThan(KNEE);
    expect(up).toBeLessThanOrEqual(CEILING);
    expect(shapeSample(-value, gain)).toBeCloseTo(-up, 10);
  }
});

test('the bend keeps the order of loudness and has no step at the knee', () => {
  const inputs = Array.from({ length: 200 }, (_, i) => i / 100);
  const outputs = inputs.map((v) => shapeSample(v, 1));
  for (let i = 1; i < outputs.length; i += 1) expect(outputs[i]).toBeGreaterThanOrEqual(outputs[i - 1]);
  expect(shapeSample(KNEE + 1e-6, 1) - shapeSample(KNEE, 1)).toBeCloseTo(1e-6, 9);
});

test('shaping chunks one by one gives the same samples as shaping them joined', () => {
  const a = new Float32Array([0.05, 0.3, -0.45]);
  const b = new Float32Array([0.6, -0.01]);
  const joined = new Float32Array([...a, ...b]);
  expect([...louden(a), ...louden(b)]).toEqual([...louden(joined)]);
});

test("the samples handed over are left as they were", () => {
  const samples = new Float32Array([0.25, 0.5]);
  louden(samples);
  expect([...samples]).toEqual([0.25, 0.5]);
});
