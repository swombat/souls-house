// Server timestamps share a clock; only elapsed monotonic time comes from the browser.
export function runtimeServerTime(serverTime, receivedAt, monotonicNow) {
  const timestamp = Date.parse(serverTime);
  return Number.isFinite(timestamp) ? timestamp + Math.max(0, monotonicNow - receivedAt) : null;
}

export function runtimeContactUncertain(interaction, now) {
  const lastReport = Date.parse(interaction.last_report_at);
  return (
    interaction.reporter_health !== 'live' || now == null || !Number.isFinite(lastReport) || now - lastReport > 30000
  );
}

export function runtimeSilenceLabel(interaction, now) {
  if (
    interaction.narration_shared === false ||
    !interaction.run_id ||
    !interaction.active ||
    interaction.status !== 'running' ||
    now == null
  )
    return null;
  const started = Date.parse(interaction.started_at);
  if (!Number.isFinite(started)) return null;
  const lastPost = Date.parse(interaction.last_resident_post_at);
  const elapsed = now - Math.max(started, Number.isFinite(lastPost) ? lastPost : started);
  if (elapsed < 120000) return null;
  const contact = runtimeContactUncertain(interaction, now) ? 'runtime contact uncertain' : 'runtime active';
  const minutes = Math.floor(elapsed / 60000);
  const elapsedLabel =
    Number.isFinite(lastPost) && lastPost >= started
      ? `Last resident update: ${minutes} min ago`
      : `${minutes} min since run start · no resident post yet`;
  return `${elapsedLabel} · ${contact}`;
}

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
