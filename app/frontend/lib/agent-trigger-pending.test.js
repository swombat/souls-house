import { pendingEntry, takenUpIds } from './agent-trigger-pending.js';

const room = (overrides = {}) => ({
  activeRuntimeAgentIds: [],
  runtimeInteractions: [],
  latestReplies: {},
  ...overrides,
});

test("a resident is taken up by their own new run, row or reply, never by anyone else's", () => {
  const before = room({
    activeRuntimeAgentIds: ['two'],
    runtimeInteractions: [{ id: 'r0', agent_id: 'two' }],
    latestReplies: { one: 'm0' },
  });
  const pending = { one: pendingEntry('one', before), two: pendingEntry('two', before) };
  expect(takenUpIds(pending, before)).toEqual([]);

  const othersMoved = room({
    activeRuntimeAgentIds: ['two', 'three'],
    runtimeInteractions: [
      { id: 'r0', agent_id: 'two' },
      { id: 'r1', agent_id: 'three' },
    ],
    latestReplies: { one: 'm0', three: 'm1' },
  });
  expect(takenUpIds(pending, othersMoved)).toEqual([]);

  expect(takenUpIds(pending, room({ ...othersMoved, latestReplies: { one: 'm2' } }))).toEqual(['one']);
  expect(
    takenUpIds(
      pending,
      room({
        ...before,
        runtimeInteractions: [
          { id: 'r0', agent_id: 'two' },
          { id: 'r2', agent_id: 'two' },
        ],
      })
    )
  ).toEqual(['two']);
});
