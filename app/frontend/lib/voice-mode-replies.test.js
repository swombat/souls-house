import { expect, test } from 'vitest';
import { initialSeen, newReplies } from './voice-mode-replies';

const reply = (id, extra = {}) => ({
  id,
  role: 'assistant',
  voice_available: true,
  completed: true,
  streaming: false,
  content: 'Hello.',
  ...extra,
});

test('opening voice mode reads none of the backlog, but a reply still arriving is read once complete', () => {
  const page = [
    reply('old'),
    { id: 'mine', role: 'user', content: 'hi' },
    reply('live', { streaming: true, completed: false }),
  ];
  const seen = initialSeen(page);
  expect(newReplies(page, seen)).toEqual([]);
  const later = [...page.slice(0, 2), reply('live')];
  expect(newReplies(later, seen)).toEqual(['live']);
  expect(newReplies(later, seen)).toEqual([]);
});

test('only finished, voiced resident messages with words are read, progress notes included', () => {
  const seen = new Set();
  const messages = [
    reply('progress', { progress_message: true }),
    reply('unvoiced', { voice_available: false }),
    reply('thinking', { content: '  ' }),
    reply('streaming', { streaming: true }),
    { id: 'human', role: 'user', content: 'Me.', voice_available: false },
  ];
  expect(newReplies(messages, seen)).toEqual(['progress']);
});
