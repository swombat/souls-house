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

test('a committed turn supersedes a reply still arriving: it is not read when it completes', () => {
  const pending = reply('old-turn', 3, { streaming: true, completed: false });
  const picker = createReplyPicker([pending]);
  picker.hold();
  expect(picker.take([reply('old-turn', 3)])).toEqual([]);
  picker.commit([reply('old-turn', 3)]);
  expect(picker.take([reply('old-turn', 3)])).toEqual([]);
});

test('nothing is read while the person is speaking; a note landing then is superseded by the sent turn', () => {
  const picker = createReplyPicker([reply('old', 1)]);
  picker.hold();
  const during = reply('during', 2, { progress_message: true });
  expect(picker.take([reply('old', 1), during])).toEqual([]);
  picker.commit([reply('old', 1), during]);
  expect(picker.take([reply('old', 1), during, reply('answer', 3)])).toEqual(['answer']);
});

test('a discarded burst (noise, not speech) consumes nothing: what landed during it is read after (#748)', () => {
  const picker = createReplyPicker([]);
  const first = reply('first', 10, { runtime_interaction_id: 'run' });
  picker.hold();
  expect(picker.take([first])).toEqual([]);
  picker.discard();
  expect(picker.take([first])).toEqual(['first']);
  const final = reply('final', 11, { runtime_interaction_id: 'run' });
  expect(picker.take([first, final])).toEqual(['final']);
});

test('a reply still arriving when noise starts is read once it completes, if the burst is discarded', () => {
  const pending = reply('arriving', 3, { streaming: true, completed: false });
  const picker = createReplyPicker([pending]);
  picker.hold();
  expect(picker.take([reply('arriving', 3)])).toEqual([]);
  picker.discard();
  expect(picker.take([reply('arriving', 3)])).toEqual(['arriving']);
});

test('speaking over one message of a run silences only that message: the run is read on afterwards (#755)', () => {
  const picker = createReplyPicker([]);
  const progress = reply('progress', 10, { progress_message: true, runtime_interaction_id: 'old-run' });
  expect(picker.take([progress])).toEqual(['progress']);
  picker.hold();
  picker.commit([progress]);
  const next = reply('next', 11, { progress_message: true, runtime_interaction_id: 'old-run' });
  expect(picker.take([progress, next])).toEqual(['next']);
  const oldFinal = reply('old-final', 12, { runtime_interaction_id: 'old-run' });
  expect(picker.take([progress, next, oldFinal])).toEqual(['old-final']);
});

test('a run message on the page or still arriving at the commit stays silent; the same run after it is read', () => {
  const picker = createReplyPicker([]);
  const playing = reply('playing', 10, { runtime_interaction_id: 'run' });
  expect(picker.take([playing])).toEqual(['playing']);
  picker.hold();
  const during = reply('during', 11, { progress_message: true, runtime_interaction_id: 'run' });
  const arriving = reply('arriving', 11, { streaming: true, completed: false, runtime_interaction_id: 'run' });
  picker.commit([playing, during, arriving]);
  const done = reply('arriving', 11, { runtime_interaction_id: 'run' });
  const after = reply('after', 12, { runtime_interaction_id: 'run' });
  expect(picker.take([playing, during, done, after])).toEqual(['after']);
});

test('without run provenance only the superseded message itself stays silent', () => {
  const picker = createReplyPicker([]);
  const earlier = reply('earlier', 10);
  picker.take([earlier]);
  picker.hold();
  picker.commit([earlier]);
  expect(picker.take([earlier, reply('later', 11)])).toEqual(['later']);
});
