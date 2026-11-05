import { expect, test } from 'vitest';
import { createReplyPicker } from './voice-mode-replies';

const reply = (id, minute, extra = {}) => ({
  id,
  role: 'assistant',
  voice_available: true,
  completed: true,
  streaming: false,
  content: 'Hello.',
  created_at: `2026-11-02T09:${String(minute).padStart(2, '0')}:00Z`,
  ...extra,
});

test('opening voice mode reads none of the backlog, but a reply still arriving is read once complete', () => {
  const page = [reply('old', 1), { id: 'mine', role: 'user', content: 'hi', created_at: '2026-11-02T09:02:00Z' }];
  const live = reply('live', 3, { streaming: true, completed: false });
  const picker = createReplyPicker([...page, live]);
  expect(picker.take([...page, live])).toEqual([]);
  expect(picker.take([...page, reply('live', 3)])).toEqual(['live']);
  expect(picker.take([...page, reply('live', 3)])).toEqual([]);
  expect(picker.take([...page, reply('live', 3), reply('next', 4)])).toEqual(['next']);
});

test('only finished, voiced resident messages with words are read, progress notes included', () => {
  const picker = createReplyPicker([]);
  const messages = [
    reply('progress', 5, { progress_message: true }),
    reply('unvoiced', 5, { voice_available: false }),
    reply('thinking', 5, { content: '  ' }),
    reply('streaming', 5, { streaming: true }),
    { id: 'human', role: 'user', content: 'Me.', voice_available: false, created_at: '2026-11-02T09:05:00Z' },
  ];
  expect(picker.take(messages)).toEqual(['progress']);
});

test('older history loaded by scrolling is never read, whatever its ids look like', () => {
  const current = reply('zzz-current', 30);
  const picker = createReplyPicker([current]);
  const older = [reply('aaa-earlier', 10), reply('zzz-earliest', 5, { progress_message: true })];
  expect(picker.take([...older, current])).toEqual([]);
  expect(picker.take([...older, current, reply('mmm-new', 31)])).toEqual(['mmm-new']);
});

test('a reply still arriving when the person speaks is read once it completes, after the turn is sent (#758)', () => {
  const pending = reply('old-turn', 3, { streaming: true, completed: false });
  const picker = createReplyPicker([pending]);
  picker.hold();
  expect(picker.take([reply('old-turn', 3)])).toEqual([]);
  picker.release();
  expect(picker.take([reply('old-turn', 3)])).toEqual(['old-turn']);
});

test('nothing is read while the person is speaking; what landed then is read after, before later replies', () => {
  const picker = createReplyPicker([reply('old', 1)]);
  picker.hold();
  const during = reply('during', 2, { progress_message: true });
  expect(picker.take([reply('old', 1), during])).toEqual([]);
  picker.release();
  expect(picker.take([reply('old', 1), during, reply('answer', 3)])).toEqual(['during', 'answer']);
});

test('each message is read once, whatever run it belongs to, across bursts (#755)', () => {
  const picker = createReplyPicker([]);
  const progress = reply('progress', 10, { progress_message: true, runtime_interaction_id: 'run' });
  expect(picker.take([progress])).toEqual(['progress']);
  picker.hold();
  picker.release();
  const next = reply('next', 11, { progress_message: true, runtime_interaction_id: 'run' });
  expect(picker.take([progress, next])).toEqual(['next']);
  expect(picker.take([progress, next])).toEqual([]);
});
