export function mergeRuntimeActivity(initial = [], updates = []) {
  const byId = new Map(initial.map((row) => [row.id, row]));
  for (const row of updates) {
    const previous = byId.get(row.id);
    if (!previous || (row.revision || 0) >= (previous.revision || 0)) byId.set(row.id, row);
  }
  return [...byId.values()].sort((a, b) => {
    const difference = new Date(a.created_at) - new Date(b.created_at);
    return difference || String(a.id).localeCompare(String(b.id));
  });
}

// Activity is fetched independently of Inertia's message snapshot. Compare
// against that snapshot, not the last poll, so a failed reload can be retried.
export function runtimeActivityNeedsMessageRefresh(initial = [], updates = []) {
  const byId = new Map(initial.map((row) => [row.id, row]));
  return updates.some((row) => {
    const previous = byId.get(row.id);
    return (
      (row.reply_count || 0) > (previous?.reply_count || 0) ||
      (previous?.active && !row.active && (row.revision || 0) >= (previous.revision || 0))
    );
  });
}
