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
