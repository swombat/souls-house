import { expect, test } from 'vitest';
import { formatElapsed, voiceNoteFile, voiceNoteTitle } from './mic-recorder.js';

test('a take loses its codec parameters, which the recording upload refuses, and gets the matching extension', () => {
  const webm = voiceNoteFile([new Blob(['a'])], 'audio/webm;codecs=opus', 'Voice note · 26 Nov, 09:47');
  expect([webm.type, webm.name]).toEqual(['audio/webm', 'Voice note · 26 Nov, 09-47.webm']);
  expect(webm.type).toMatch(/^(audio|video)\/[\w.+-]+$/);

  const safari = voiceNoteFile([new Blob(['a'])], 'audio/mp4', 'Idea');
  expect([safari.type, safari.name]).toEqual(['audio/mp4', 'Idea.m4a']);

  const unnamed = voiceNoteFile([new Blob(['a'])], '', '');
  expect([unnamed.type, unnamed.name]).toEqual(['audio/webm', 'Voice note.webm']);
});

test('the default title names the day and the minute', () => {
  expect(voiceNoteTitle(new Date(2026, 10, 26, 9, 47))).toBe('Voice note · 26 Nov, 09:47');
});

test('elapsed time reads as minutes and seconds', () => {
  expect([formatElapsed(0), formatElapsed(9_999), formatElapsed(61_000), formatElapsed(-5)]).toEqual([
    '0:00',
    '0:09',
    '1:01',
    '0:00',
  ]);
});
