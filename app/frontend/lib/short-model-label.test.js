import { expect, test } from 'vitest';
import { shortModelLabel } from './short-model-label.js';

test('drops the shared family prefix', () => {
  expect(shortModelLabel('Claude Opus 5.5')).toBe('Opus 5.5');
  expect(shortModelLabel('Claude Fable 5.1')).toBe('Fable 5.1');
  expect(shortModelLabel('GPT-6.1 Sol')).toBe('Sol 6.1');
  expect(shortModelLabel('GPT-6 Astra Pro')).toBe('Astra Pro 6');
});

test('leaves other labels alone', () => {
  expect(shortModelLabel('DeepSeek V4.1 Flash')).toBe('DeepSeek V4.1 Flash');
  expect(shortModelLabel(null)).toBe(null);
  expect(shortModelLabel('openai/gpt-6-astra')).toBe('openai/gpt-6-astra');
});
