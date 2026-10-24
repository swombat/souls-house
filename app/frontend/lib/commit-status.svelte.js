// Batched, cached commit statuses for chat badges. Rendering a message only
// reads this store; lookups are queued, sent together, and answered from the
// server's cache, so chat rendering never waits on GitHub.
//
// A badge is a claim about now, so it has to keep being true while it is on
// screen:
// - every mounted reference is re-asked on a timer (known answers every few
//   minutes, unknown ones sooner);
// - a known answer older than EXPIRE_MS is not shown, even if no refresh has
//   landed, so a rocket cannot outlive a rollback by more than that;
// - a failed refresh clears the answer rather than keeping the old one;
// - when the server reports a different running revision or master, every
//   answer measured against the old pair is dropped and re-asked.
//
// Keys are references as the server takes them: a bare sha, or repo@sha for
// a commit URL. Answers belong to the account whose chat is on screen (its
// repositories, its token), so switching account drops them all.

const BATCH_DELAY_MS = 60;
const MAX_PER_REQUEST = 50;
const FRESH_MS = 3 * 60 * 1000;
const UNKNOWN_RETRY_MS = 60 * 1000;
const EXPIRE_MS = 6 * 60 * 1000;
const TICK_MS = 30 * 1000;
const KNOWN = ['deployed', 'merged', 'unmerged', 'on_default', 'off_default'];

const entries = $state({}); // sha -> { status, at }
let clock = $state(0);
const askedAt = new Map();
const inFlight = new Set();
const watchers = new Map();
let queue = new Set();
let timer = null;
let ticker = null;
let revision = null;
let endpoint = null;

// The account whose repositories answer; set by whatever shows a badge.
export function setCommitStatusAccount(accountId) {
  const next = accountId ? `/accounts/${encodeURIComponent(accountId)}/commit_statuses` : null;
  if (next === endpoint) return;
  endpoint = next;
  revision = null;
  for (const sha of Object.keys(entries)) delete entries[sha];
  askedAt.clear();
  for (const sha of watchers.keys()) requestCommitStatus(sha);
}

export function commitStatus(sha) {
  void clock; // re-evaluate on every tick, so expiry shows without a refresh
  const entry = entries[sha];
  if (!entry?.status) return null;
  return Date.now() - entry.at < EXPIRE_MS ? entry.status : null;
}

// Keep sha's status current while something shows it; returns the cleanup.
export function watchCommitStatus(sha) {
  watchers.set(sha, (watchers.get(sha) ?? 0) + 1);
  requestCommitStatus(sha);
  ticker ??= setInterval(tick, TICK_MS);
  return () => {
    const count = (watchers.get(sha) ?? 1) - 1;
    if (count > 0) watchers.set(sha, count);
    else watchers.delete(sha);
    if (watchers.size === 0 && ticker) {
      clearInterval(ticker);
      ticker = null;
    }
  };
}

export function requestCommitStatus(sha) {
  if (inFlight.has(sha) || queue.has(sha)) return;
  const at = askedAt.get(sha);
  const wait = entries[sha]?.status ? FRESH_MS : UNKNOWN_RETRY_MS;
  if (at !== undefined && Date.now() - at < wait) return;
  queue.add(sha);
  timer ??= setTimeout(flush, BATCH_DELAY_MS);
}

function tick() {
  clock = Date.now();
  for (const sha of watchers.keys()) requestCommitStatus(sha);
}

async function flush() {
  timer = null;
  const shas = [...queue];
  queue = new Set();
  for (let i = 0; i < shas.length; i += MAX_PER_REQUEST) {
    await load(shas.slice(i, i + MAX_PER_REQUEST));
  }
}

function record(sha, status, now) {
  entries[sha] = { status, at: now };
  askedAt.set(sha, now);
}

async function load(shas) {
  const url = endpoint;
  if (!url) return;
  shas.forEach((sha) => inFlight.add(sha));
  let body = null;
  try {
    const response = await fetch(`${url}?refs=${encodeURIComponent(shas.join(','))}`, {
      headers: { Accept: 'application/json' },
    });
    if (response.ok) body = await response.json();
  } catch {
    body = null;
  } finally {
    shas.forEach((sha) => inFlight.delete(sha));
  }

  if (url !== endpoint) return; // answered for an account no longer on screen
  const now = Date.now();
  if (!body || typeof body.statuses !== 'object' || body.statuses === null) {
    // A failed refresh is not evidence the old answer still holds.
    shas.forEach((sha) => record(sha, null, now));
    return;
  }

  if (typeof body.revision === 'string' && body.revision !== revision) {
    const changed = revision !== null;
    revision = body.revision;
    if (changed) {
      for (const sha of Object.keys(entries)) {
        if (shas.includes(sha)) continue;
        delete entries[sha];
        askedAt.delete(sha);
      }
      for (const sha of watchers.keys()) if (!shas.includes(sha)) requestCommitStatus(sha);
    }
  }

  for (const sha of shas) {
    const status = body.statuses[sha];
    record(sha, KNOWN.includes(status) ? status : null, now);
  }
}

export function resetCommitStatusesForTest() {
  for (const key of Object.keys(entries)) delete entries[key];
  askedAt.clear();
  inFlight.clear();
  watchers.clear();
  queue = new Set();
  if (timer) clearTimeout(timer);
  if (ticker) clearInterval(ticker);
  timer = null;
  ticker = null;
  revision = null;
  endpoint = null;
  clock = 0;
}
