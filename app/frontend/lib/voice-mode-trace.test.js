import { expect, test } from 'vitest';
import { createVoiceTrace } from './voice-mode-trace';

test('notes are seconds from the first, and take() empties the trace', () => {
  let t = 1000;
  const trace = createVoiceTrace({ now: () => t });
  trace.note('hidden');
  t = 1400;
  trace.note('int:muted');
  expect(trace.take()).toBe('hidden@0.0,int:muted@0.4');
  expect(trace.take()).toBe('');
  t = 9000;
  trace.note('visible');
  expect(trace.take()).toBe('visible@0.0');
});

test('a long trace keeps its newest notes', () => {
  const trace = createVoiceTrace({ now: () => 0 });
  for (let i = 0; i < 100; i++) trace.note(`n${i}`);
  const line = trace.take();
  expect(line.endsWith('n99@0.0')).toBe(true);
  expect(line).not.toContain('n0@');
  expect(line.length).toBeLessThanOrEqual(600);
});
