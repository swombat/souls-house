import { describe, expect, it } from 'vitest';
import { chatTimelineItems } from './chat-timeline';

const at = (minute) => `2026-09-27T22:${String(minute).padStart(2, '0')}:00Z`;
const message = (id, minute, extra = {}) => ({ id, created_at: at(minute), ...extra });
const run = (id, start, finish = null) => ({
  id,
  created_at: at(start),
  started_at: at(start),
  finished_at: finish === null ? null : at(finish),
  active: finish === null,
});
const ids = (items) => items.map((item) => item.id);

describe('chat activity timeline', () => {
  it('keeps every active run below messages and completed runs, regardless of arrival order', () => {
    const messages = [message('a', 1), message('b', 8)];
    const runs = [run('later', 3), run('finished', 2, 5), run('earlier', 0)];
    expect(ids(chatTimelineItems(messages, messages, runs))).toEqual([
      'message-a',
      'runtime-finished',
      'message-b',
      'runtime-earlier',
      'runtime-later',
    ]);
    expect(runs.map((row) => row.id)).toEqual(['later', 'finished', 'earlier']);
  });

  it('moves a completed run to its finish time and leaves other active work at the bottom', () => {
    const messages = [message('reply', 4), message('later', 9)];
    const active = run('a', 1);
    expect(ids(chatTimelineItems(messages, messages, [active]))).toEqual([
      'message-reply',
      'message-later',
      'runtime-a',
    ]);
    const items = chatTimelineItems(messages, messages, [run('other', 0), run('a', 1, 6)]);
    expect(ids(items)).toEqual(['message-reply', 'runtime-a', 'message-later', 'runtime-other']);
    expect(items[1].created_at).toBe(at(6));
  });

  it('orders completed runs by finish, not start, and puts equal-time speech first', () => {
    const messages = [message('reply', 5)];
    expect(ids(chatTimelineItems(messages, messages, [run('slow', 0, 8), run('fast', 3, 5)]))).toEqual([
      'message-reply',
      'runtime-fast',
      'runtime-slow',
    ]);
  });

  it('falls back to start or creation for older inactive records without a finish time', () => {
    const messages = [message('a', 4)];
    const items = chatTimelineItems(messages, messages, [
      { id: 'legacy', created_at: at(0), started_at: at(2), active: false },
      { id: 'old', created_at: at(6), active: false },
    ]);
    expect(ids(items)).toEqual(['runtime-legacy', 'message-a', 'runtime-old']);
    expect(items[0].created_at).toBe(at(2));
  });

  it('preserves progress groups and hidden-message interruptions', () => {
    const progress = { progress_message: true, runtime_interaction_id: 1, agent_id: 1 };
    const messages = [
      message('a', 1, progress),
      message('b', 3, progress),
      message('hidden', 4),
      message('c', 6, progress),
    ];
    const visible = messages.filter((row) => row.id !== 'hidden');
    const items = chatTimelineItems(messages, visible, [run('done', 0, 2)]);
    expect(ids(items)).toEqual(['message-a', 'runtime-done', 'message-c']);
    expect(items[0].group.messages.map((row) => row.id)).toEqual(['a', 'b']);
    expect(items[2].group.continued).toBe(true);
  });

  it('handles empty conversations and missing activity', () => {
    expect(chatTimelineItems()).toEqual([]);
    expect(chatTimelineItems([], [], null)).toEqual([]);
    expect(ids(chatTimelineItems([], [], [run('a', 1)]))).toEqual(['runtime-a']);
  });
});
