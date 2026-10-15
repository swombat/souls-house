import { expect, test } from 'vitest';
import { songReference, songOffer } from './song-reference';

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

test('outside offers have two or three trimmed fields and keep the legacy API separate', () => {
  const raw = '[[song:https://youtu.be/y8AWFf7EAc4 | A title | An artist]]\n';
  expect(songReference({ type: 'paragraph', raw })).toBeNull();
  expect(songOffer({ type: 'paragraph', raw })).toEqual({
    url: 'https://youtu.be/y8AWFf7EAc4',
    title: 'A title',
    artist: 'An artist',
  });
  expect(songOffer({ type: 'paragraph', raw: '[[song:https://example.com | Title]]' })).toEqual({
    url: 'https://example.com',
    title: 'Title',
    artist: '',
  });
  expect(songOffer({ type: 'paragraph', raw: '[[song:https://example.com]]' })).toEqual({
    url: 'https://example.com',
    title: '',
    artist: '',
  });
  expect(songOffer({ type: 'paragraph', raw: '[[song:https://example.com | | Artist]]' })?.title).toBe('');
  expect(songOffer({ type: 'paragraph', raw: '[[song:Abc123]]' })).toBeNull();
});

test('only backslash, pipes and brackets have escapes, in every offer field', () => {
  expect(
    songOffer({
      type: 'paragraph',
      raw: String.raw`[[song:https://example.com/a\|b | A \[title\] \\ \| | \[artist\]]]`,
    })
  ).toEqual({
    url: 'https://example.com/a|b',
    title: 'A [title] \\ |',
    artist: '[artist]',
  });
});

test.each([
  String.raw`[[song:https://example.com | Unknown \q]]`,
  String.raw`[[song:https://example.com | dangling\]]`,
  '[[song:https://example.com | Title | Artist | Extra]]',
  '[[song:https://example.com | [Title]]]',
  '[[song:https://example.com | Title\nArtist]]',
  '[[song:https://example.com | Title\rArtist]]',
  '[[song: | Title]]',
  '[[song:../secret]]',
  '[[song:https://example.com | Title]',
  '\\[[song:https://example.com | Title]]',
  '`[[song:https://example.com | Title]]`',
  'Before [[song:https://example.com | Title]]',
  '[[song:https://example.com | Title]] after',
])('malformed offers remain plain text: %s', (raw) => {
  expect(songOffer({ type: 'paragraph', raw })).toBeNull();
});

test('offers only apply to paragraphs; URL validity belongs to the server', () => {
  expect(songOffer({ type: 'code', raw: '[[song:https://example.com | Title]]' })).toBeNull();
  expect(songOffer({ type: 'paragraph', raw: '[[song:javascript:alert(1) | Title]]' })?.url).toBe(
    'javascript:alert(1)'
  );
});
