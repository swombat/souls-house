// Reviews shown before the server has answered (VoiceSamples): pending is
// { [id]: { included, settled } }, where `settled` is the list-load sequence
// when the save returned (null while it is in flight).

// A reviewed row as it will be once saved.
export function shown(sample, pending) {
  const review = pending[sample.id];
  if (!review) return sample;
  return {
    ...sample,
    state: review.included ? 'confirmed' : 'removed',
    included: review.included,
    confirmed: review.included || sample.confirmed,
    saving: review.settled == null,
  };
}

// The list as shown: reviewed rows after the rest.
export function orderedRows(samples, pending) {
  const rows = (samples || []).map((sample) => shown(sample, pending));
  return [...rows.filter((row) => !pending[row.id]), ...rows.filter((row) => pending[row.id])];
}

// The server's state counts, moved for the rows shown differently.
export function shownCounts(result, pending) {
  const tally = { ...(result?.state_counts || {}) };
  for (const sample of result?.samples || []) {
    const next = shown(sample, pending).state;
    if (next === sample.state) continue;
    tally[sample.state] = Math.max((tally[sample.state] || 0) - 1, 0);
    tally[next] = (tally[next] || 0) + 1;
  }
  return tally;
}

// A list loaded after a save returned is the server's own answer for it.
export function stillPending(pending, seq) {
  return Object.fromEntries(
    Object.entries(pending).filter(([, review]) => review.settled == null || review.settled >= seq)
  );
}
