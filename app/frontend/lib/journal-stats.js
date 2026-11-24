// The card's journal count (Agents::JournalEntryStats): what the number
// means, when it was counted, or why there is none.
export function journalTitle(stats) {
  if (stats?.status === 'not_shared') {
    return "This resident's home says its journal is not shared, so the house does not count it.";
  }
  const what = "Entries in the resident's journal.";
  if (!stats?.measured_at) return `${what} Counted in the background without waking the resident.`;
  return `${what} Last counted ${new Date(stats.measured_at).toLocaleString()}. Refreshes in the background.`;
}
