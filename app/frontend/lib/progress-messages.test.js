import { describe, expect, it } from 'vitest';
import { isVisibleChatMessage } from './chat-message-state';
import { elapsedBetween, progressMessageGroups } from './progress-messages';

const post = (id, overrides = {}) => ({
  id,
  agent_id: 1,
  runtime_interaction_id: 10,
  role: 'assistant',
  ...overrides,
});
const sizes = (messages, visible = messages) =>
  progressMessageGroups(messages, visible).map((group) => group.messages.length);

describe('progress grouping', () => {
  it('groups only consecutive ordinary posts from the same resident and wake', () => {
    expect(sizes([post(1), post(2), post(3)])).toEqual([3]);
    for (const boundary of [
      { role: 'user' },
      { agent_id: 2 },
      { runtime_interaction_id: 11 },
      { runtime_interaction_id: null },
      { agent_id: null },
    ]) {
      expect(sizes([post(1), post(2, boundary), post(3)])).toEqual([1, 1, 1]);
    }
  });
  it('does not bridge a deleted or hidden interruption', () => {
    expect(sizes([post(1, { progress_break_after: true }), post(3)])).toEqual([1, 1]);
    const messages = [post(1), post(2, { role: 'user' }), post(3)];
    expect(sizes(messages, [messages[0], messages[2]])).toEqual([1, 1]);
  });
  it('marks continuation without changing or joining message bodies', () => {
    const messages = [post(1), post(2, { role: 'user' }), post(3)];
    const groups = progressMessageGroups(messages);
    expect(groups[2].continued).toBe(true);
    expect(groups[2].message).toBe(messages[2]);
    expect(groups[0].continued).toBe(false);
  });
  it('caps rendering groups without truncating messages', () => {
    const messages = Array.from({ length: 41 }, (_, index) => post(index));
    expect(sizes(messages)).toEqual([20, 20, 1]);
    expect(progressMessageGroups(messages)[1].continued).toBe(true);
  });
  it('joins a loaded page boundary only when adjacent messages qualify', () => {
    const messages = [post(1), post(2), post(3), post(4)];
    expect(sizes(messages.slice(2))).toEqual([2]);
    expect(sizes(messages)).toEqual([4]);
  });
});

it('labels elapsed wall time including zero, minutes and hours, not measured effort', () => {
  const start = '2026-09-27T08:00:00Z';
  expect(elapsedBetween(start, start)).toBe('0s elapsed');
  expect(elapsedBetween(start, '2026-09-27T08:00:32Z')).toBe('32s elapsed');
  expect(elapsedBetween(start, '2026-09-27T08:02:03Z')).toBe('2m 03s elapsed');
  expect(elapsedBetween(start, '2026-09-27T10:02:03Z')).toBe('2h 02m elapsed');
  expect(elapsedBetween(start, 'invalid')).toBeNull();
  expect(elapsedBetween(start, '2026-09-26T08:00:00Z')).toBeNull();
});

it('keeps deliberately published JSON progress visible', () => {
  expect(
    isVisibleChatMessage(post(1, { progress_message: true, role: 'assistant', content: '{"checked":true}' }))
  ).toBe(true);
});

it('sorts late arrivals before grouping, so an older interruption splits speech', () => {
  const first = post(1, { created_at: '2026-09-27T08:00:00Z' });
  const last = post(3, { created_at: '2026-09-27T08:02:00Z' });
  const late = post(2, { role: 'user', created_at: '2026-09-27T08:01:00Z' });
  const arrivalOrder = [first, last, late];
  const groups = progressMessageGroups(arrivalOrder);
  expect(groups.map((group) => group.messages.map((message) => message.id))).toEqual([[1], [2], [3]]);
  expect(groups[2].isTail).toBe(true);
  expect(arrivalOrder).toEqual([first, last, late]);
  expect(progressMessageGroups(arrivalOrder, [first, last]).map((group) => group.messages.length)).toEqual([1, 1]);
});

it('keeps equal-timestamp interruptions in their existing order', () => {
  const messages = [post(1), post(2, { role: 'user' }), post(3)].map((message) => ({
    ...message,
    created_at: '2026-09-27T08:00:00Z',
  }));
  expect(progressMessageGroups(messages).map((group) => group.message.id)).toEqual([1, 2, 3]);
});

it('ignores legacy opt-in flags when grouping ordinary messages', () => {
  expect(sizes([post(1, { progress_message: false }), post(2), post(3, { progress_message: true })])).toEqual([3]);
});

it('keeps attachment-only ordinary posts visible and groupable', () => {
  const attachment = post(2, { content: '', files_json: [{ filename: 'result.png' }] });
  expect(isVisibleChatMessage(attachment)).toBe(true);
  expect(sizes([post(1), attachment])).toEqual([2]);
});
