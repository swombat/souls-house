// Having samples cut ahead of play. A sample from a long recording takes
// seconds to cut, so the page asks the server for the next few playable ones
// (it cuts them in one pass per recording and holds them for ten minutes).

export const WARM_AHEAD = 8;
const ASK_AGAIN_MS = 5 * 60_000;

// The ids worth asking for after `from` (or from the top), marking them in
// `warmed` (id|digest -> when asked).
export function warmIds(rows, { from = null, heard, full, warmed, now = Date.now() }) {
  const start = from == null ? 0 : rows.findIndex((row) => row.id === from) + 1;
  const picked = rows
    .slice(Math.max(start, 0))
    .filter((row) => row.audio_url && !String(row.id).startsWith('upload-') && !heard(row))
    .filter((row) => row.state === 'review' || (row.state === 'removed' && !full))
    .filter((row) => !(now - (warmed.get(`${row.id}|${row.digest}`) ?? -Infinity) < ASK_AGAIN_MS))
    .slice(0, WARM_AHEAD);
  picked.forEach((row) => warmed.set(`${row.id}|${row.digest}`, now));
  return picked.map((row) => row.id);
}

// Fire and forget: a failed ask only means the play cuts on demand.
export function askToWarm(base, ids, headers) {
  if (!ids.length) return;
  fetch(`${base}/samples/warm`, { method: 'POST', headers, body: JSON.stringify({ ids }) }).catch(() => {});
}

// play() is refused with AbortError when a pause or a new source interrupts
// it; that is the person (or a refresh) changing their mind, not a failure.
export const interrupted = (failure) => failure?.name === 'AbortError';
