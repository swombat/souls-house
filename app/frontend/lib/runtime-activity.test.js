import {
  mergeRuntimeActivity,
  runtimeActivityNeedsMessageRefresh,
  runtimeContactUncertain,
  runtimeServerTime,
  runtimeSilenceLabel,
} from './runtime-activity';

const serverTime = '2026-10-12T10:05:00Z';
const now = Date.parse(serverTime);
const running = {
  run_id: 'run',
  active: true,
  status: 'running',
  agent_name: 'Resident',
  started_at: '2026-10-12T10:00:00Z',
  last_resident_post_at: null,
  reporter_health: 'live',
  last_report_at: serverTime,
};

test('advances server time using only monotonic elapsed time, independent of client wall time', () => {
  expect(runtimeServerTime(serverTime, 500, 60500)).toBe(now + 60000);
  expect(runtimeServerTime(serverTime, 500, 499)).toBe(now);
  expect(runtimeServerTime(null, 500, 60500)).toBeNull();
  expect(runtimeServerTime('invalid', 500, 60500)).toBeNull();
});

test('silence starts at two minutes, floors minutes, and never claims task progress', () => {
  const start = Date.parse(running.started_at);
  expect(runtimeSilenceLabel(running, start + 119999)).toBeNull();
  const fresh = { ...running, last_report_at: new Date(start + 120000).toISOString() };
  expect(runtimeSilenceLabel(fresh, start + 120000)).toBe(
    '2 min since run start · no resident post yet · runtime active'
  );
  expect(runtimeSilenceLabel(running, now + 29999)).toBe(
    '5 min since run start · no resident post yet · runtime active'
  );
});

test('does not expose the new elapsed-time status when narration sharing is off', () => {
  expect(runtimeSilenceLabel({ ...running, narration_shared: false }, now)).toBeNull();
  expect(
    runtimeSilenceLabel({ ...running, narration_shared: false, last_resident_post_at: running.started_at }, now)
  ).toBeNull();
});

test('a reply resets silence without being moved earlier than the run start', () => {
  const replied = { ...running, last_resident_post_at: '2026-10-12T10:04:00Z' };
  expect(runtimeSilenceLabel(replied, now)).toBeNull();
  expect(runtimeSilenceLabel(replied, now + 60000)).toBe('Last resident update: 2 min ago · runtime contact uncertain');
  expect(runtimeSilenceLabel({ ...running, last_resident_post_at: '2026-10-12T09:59:00Z' }, now)).toBe(
    '5 min since run start · no resident post yet · runtime active'
  );
});

test.each(['queued', 'preparing', 'completed', 'failed', 'timed_out', 'cancelled', 'busy', 'outcome_unknown'])(
  'never shows silence for %s even if an old snapshot says active',
  (status) => {
    expect(runtimeSilenceLabel({ ...running, status }, now)).toBeNull();
  }
);

test('requires active execution and valid server and start timestamps', () => {
  expect(runtimeSilenceLabel({ ...running, run_id: null }, now)).toBeNull();
  expect(runtimeSilenceLabel({ ...running, active: false }, now)).toBeNull();
  expect(runtimeSilenceLabel({ ...running, started_at: null }, now)).toBeNull();
  expect(runtimeSilenceLabel({ ...running, started_at: 'invalid' }, now)).toBeNull();
  expect(runtimeSilenceLabel(running, null)).toBeNull();
});

test('contact becomes uncertain beyond thirty seconds even when the snapshot still says live', () => {
  expect(runtimeContactUncertain(running, now + 30000)).toBe(false);
  expect(runtimeContactUncertain(running, now + 30001)).toBe(true);
  expect(runtimeSilenceLabel(running, now + 30001)).toBe(
    '5 min since run start · no resident post yet · runtime contact uncertain'
  );
});

test.each([
  { reporter_health: 'stale' },
  { reporter_health: 'connecting' },
  { reporter_health: undefined },
  { last_report_at: null },
  { last_report_at: 'invalid' },
])('missing or uncertain reporting never implies live task progress (%j)', (reporting) => {
  expect(runtimeContactUncertain({ ...running, ...reporting }, now)).toBe(true);
  expect(runtimeSilenceLabel({ ...running, ...reporting }, now)).toBe(
    '5 min since run start · no resident post yet · runtime contact uncertain'
  );
});

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
