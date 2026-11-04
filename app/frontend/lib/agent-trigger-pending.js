// The trigger bar's per-resident waits (#672). Asking one resident holds
// only that resident's button; each wait remembers what the room looked like
// when they were asked, and ends when the ask is taken up.

// room: { activeRuntimeAgentIds, runtimeInteractions, latestReplies }
export function pendingEntry(id, room) {
  return {
    wasActive: room.activeRuntimeAgentIds.includes(id),
    rowIds: new Set(room.runtimeInteractions.filter((row) => row.agent_id === id).map((row) => row.id)),
    replyId: room.latestReplies[id] ?? null,
  };
}

// Taken up once a run of theirs starts that wasn't running when they were
// asked, or a new runtime row of theirs appears. External residents post a
// finished message instead of running here, so their own new reply counts.
export function takenUpIds(pending, room) {
  return Object.keys(pending).filter((id) => {
    const entry = pending[id];
    if (room.activeRuntimeAgentIds.includes(id) && !entry.wasActive) return true;
    if (room.runtimeInteractions.some((row) => row.agent_id === id && !entry.rowIds.has(row.id))) return true;
    const reply = room.latestReplies[id];
    return Boolean(reply) && reply !== entry.replyId;
  });
}
