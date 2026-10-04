// Batched, cached commit statuses for chat badges. Rendering a message only
// reads this store; lookups are queued, sent together, and answered from the
// server's cache, so chat rendering never waits on GitHub.

const BATCH_DELAY_MS = 60;
const MAX_PER_REQUEST = 50;
const FRESH_MS = 5 * 60 * 1000;

const statuses = $state({});
const fetchedAt = new Map();
const inFlight = new Set();
let queue = new Set();
let timer = null;

export function commitStatus(sha) {
  return statuses[sha] ?? null;
}

export function requestCommitStatus(sha) {
  const at = fetchedAt.get(sha);
  if (inFlight.has(sha) || queue.has(sha) || (at && Date.now() - at < FRESH_MS)) return;
  queue.add(sha);
  timer ??= setTimeout(flush, BATCH_DELAY_MS);
}

async function flush() {
  timer = null;
  const shas = [...queue];
  queue = new Set();
  for (let i = 0; i < shas.length; i += MAX_PER_REQUEST) {
    await load(shas.slice(i, i + MAX_PER_REQUEST));
  }
}

async function load(shas) {
  shas.forEach((sha) => inFlight.add(sha));
  try {
    const response = await fetch(`/admin/commit_statuses?shas=${encodeURIComponent(shas.join(','))}`, {
      headers: { Accept: 'application/json' },
    });
    if (!response.ok) return;
    const body = await response.json();
    const now = Date.now();
    for (const sha of shas) {
      const status = body?.statuses?.[sha];
      statuses[sha] = ['deployed', 'merged', 'unmerged'].includes(status) ? status : null;
      // Unknown answers are retried sooner than known ones.
      fetchedAt.set(sha, statuses[sha] ? now : now - FRESH_MS + 60 * 1000);
    }
  } catch {
    // Unknown stays unbadged; a later render may ask again.
  } finally {
    shas.forEach((sha) => inFlight.delete(sha));
  }
}

export function resetCommitStatusesForTest() {
  for (const key of Object.keys(statuses)) delete statuses[key];
  fetchedAt.clear();
  inFlight.clear();
  queue = new Set();
  if (timer) clearTimeout(timer);
  timer = null;
}
