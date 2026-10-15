import { expect, test } from 'vitest';
import { songReference } from './song-reference';

test('only an entire plain paragraph is a song reference', () => {
  expect(songReference({ type: 'paragraph', raw: '[[song:Abc123]]\n' })).toBe('Abc123');
  for (const raw of [
    '`[[song:Abc123]]`',
    '\\[[song:Abc123]]',
    'before [[song:Abc123]]',
    '[[song:Abc123]] after',
    'before\n[[song:Abc123]]\nafter',
    '[[song:../secret]]',
    '[[song:]]',
    '[[song:Abc123]',
  ]) {
    expect(songReference({ type: 'paragraph', raw })).toBeNull();
  }
  expect(songReference({ type: 'code', raw: '[[song:Abc123]]' })).toBeNull();
});
