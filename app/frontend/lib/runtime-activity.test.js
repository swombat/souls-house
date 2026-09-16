import { mergeRuntimeActivity, runtimeActivityNeedsMessageRefresh } from './runtime-activity';

test('ignores old snapshots and keeps completion anchored at creation', () => {
  const run = { id: 'a', created_at: '2026-01-01', revision: 5, active: false };
  const other = { id: 'b', created_at: '2026-01-02', revision: 1 };
  expect(mergeRuntimeActivity([run, other], [{ ...run, active: true, revision: 2 }])).toEqual([run, other]);
});

test('reconciles newly reported replies and completion against the message snapshot', () => {
  const initial = [{ id: 'a', active: true, revision: 5, reply_count: 0 }];
  const reply = [{ id: 'a', active: true, revision: 5, reply_count: 1 }];
  const finished = [{ id: 'a', active: false, revision: 1000006, reply_count: 1 }];
  expect(runtimeActivityNeedsMessageRefresh(initial, reply)).toBe(true);
  expect(runtimeActivityNeedsMessageRefresh(reply, finished)).toBe(true);
  expect(runtimeActivityNeedsMessageRefresh([], finished)).toBe(true);
  expect(runtimeActivityNeedsMessageRefresh(finished, finished)).toBe(false);
});

test('does not reload messages for narration, old activity, or an unchanged reply count', () => {
  const initial = [{ id: 'a', active: true, revision: 5, reply_count: 1 }];
  expect(runtimeActivityNeedsMessageRefresh(initial, [{ ...initial[0], revision: 6 }])).toBe(false);
  expect(runtimeActivityNeedsMessageRefresh(initial, [{ ...initial[0], revision: 4, active: false }])).toBe(false);
  expect(runtimeActivityNeedsMessageRefresh([], [{ id: 'b', active: true, reply_count: 0 }])).toBe(false);
});
