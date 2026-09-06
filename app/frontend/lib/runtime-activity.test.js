import { mergeRuntimeActivity } from './runtime-activity';

test('ignores old snapshots and keeps completion anchored at creation', () => {
  const run = { id: 'a', created_at: '2026-01-01', revision: 5, active: false };
  const other = { id: 'b', created_at: '2026-01-02', revision: 1 };
  expect(mergeRuntimeActivity([run, other], [{ ...run, active: true, revision: 2 }])).toEqual([run, other]);
});
