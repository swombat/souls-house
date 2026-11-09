// Batched, cached conversation titles for links in chat messages. Rendering
// only reads this store; lookups are queued, sent together, and re-asked
// every few minutes while a reference is on screen, so a renamed
// conversation shows its new title without a reload. Answers belong to the
// account whose chat is on screen, so switching account drops them all.

const BATCH_DELAY_MS = 60;
const MAX_PER_REQUEST = 50;
const FRESH_MS = 5 * 60 * 1000;
const RETRY_MS = 60 * 1000;
const TICK_MS = 60 * 1000;

const titles = $state({}); // id -> title (absent or null = not a conversation the reader can open)
const askedAt = new Map();
const inFlight = new Set();
const watchers = new Map();
let queue = new Set();
let timer = null;
let ticker = null;
let endpoint = null;

export function setConversationTitleAccount(accountId) {
  const next = accountId ? `/accounts/${encodeURIComponent(accountId)}/conversation_titles` : null;
  if (next === endpoint) return;
  endpoint = next;
  for (const id of Object.keys(titles)) delete titles[id];
  askedAt.clear();
  for (const id of watchers.keys()) requestConversationTitle(id);
}

export function conversationTitle(id) {
  return titles[id] ?? null;
}

// Keep id's title current while something shows it; returns the cleanup.
export function watchConversationTitle(id) {
  watchers.set(id, (watchers.get(id) ?? 0) + 1);
  requestConversationTitle(id);
  ticker ??= setInterval(tick, TICK_MS);
  return () => {
    const count = (watchers.get(id) ?? 1) - 1;
    if (count > 0) watchers.set(id, count);
    else watchers.delete(id);
    if (watchers.size === 0 && ticker) {
      clearInterval(ticker);
      ticker = null;
    }
  };
}

export function requestConversationTitle(id) {
  if (inFlight.has(id) || queue.has(id)) return;
  const at = askedAt.get(id);
  const wait = titles[id] ? FRESH_MS : RETRY_MS;
  if (at !== undefined && Date.now() - at < wait) return;
  queue.add(id);
  timer ??= setTimeout(flush, BATCH_DELAY_MS);
}

function tick() {
  for (const id of watchers.keys()) requestConversationTitle(id);
}

async function flush() {
  timer = null;
  const ids = [...queue];
  queue = new Set();
  for (let i = 0; i < ids.length; i += MAX_PER_REQUEST) {
    await load(ids.slice(i, i + MAX_PER_REQUEST));
  }
}

async function load(ids) {
  const url = endpoint;
  if (!url) return;
  ids.forEach((id) => inFlight.add(id));
  let body = null;
  try {
    const response = await fetch(`${url}?ids=${encodeURIComponent(ids.join(','))}`, {
      headers: { Accept: 'application/json' },
    });
    if (response.ok) body = await response.json();
  } catch {
    body = null;
  } finally {
    ids.forEach((id) => inFlight.delete(id));
  }

  if (url !== endpoint) return; // answered for an account no longer on screen
  const now = Date.now();
  if (!body || typeof body.titles !== 'object' || body.titles === null) {
    // A failed lookup keeps whatever was shown and tries again soon.
    ids.forEach((id) => askedAt.set(id, now - FRESH_MS + RETRY_MS));
    return;
  }
  for (const id of ids) {
    const title = body.titles[id];
    titles[id] = typeof title === 'string' && title !== '' ? title : null;
    askedAt.set(id, now);
  }
}

export function resetConversationTitlesForTest() {
  for (const id of Object.keys(titles)) delete titles[id];
  askedAt.clear();
  inFlight.clear();
  watchers.clear();
  queue = new Set();
  if (timer) clearTimeout(timer);
  if (ticker) clearInterval(ticker);
  timer = null;
  ticker = null;
  endpoint = null;
}
