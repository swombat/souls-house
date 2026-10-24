// Keeps the conversations sidebar where the reader left it.
//
// Opening a conversation is an Inertia visit to a new page component, so the
// sidebar is unmounted and mounted again and its scroller starts at the top.
// This action remembers the scroller's position per key (account and room)
// and puts it back when the sidebar mounts again. If the open conversation
// would then be out of sight (arriving by a link, or after a reorder), it
// nudges the list just far enough to show it.

const STORAGE_PREFIX = 'chat-sidebar-scroll:';
const positions = new Map();

function readPosition(key) {
  if (positions.has(key)) return positions.get(key);
  try {
    const stored = window.sessionStorage.getItem(STORAGE_PREFIX + key);
    if (stored === null) return null;
    const top = Number(stored);
    return Number.isFinite(top) ? top : null;
  } catch {
    return null;
  }
}

function writePosition(key, top) {
  positions.set(key, top);
  try {
    window.sessionStorage.setItem(STORAGE_PREFIX + key, String(top));
  } catch {
    // Private mode or full storage: the in-memory copy still covers navigation.
  }
}

export function revealActive(node) {
  const active = node.querySelector('[aria-current="page"]');
  if (!active) return;
  const box = node.getBoundingClientRect();
  const item = active.getBoundingClientRect();
  if (item.top < box.top) {
    node.scrollTop -= box.top - item.top;
  } else if (item.bottom > box.bottom) {
    node.scrollTop += item.bottom - box.bottom;
  }
}

export function keepSidebarScroll(node, key) {
  let currentKey = key;

  function restore() {
    // A key with nothing saved (a room not visited yet) starts at the top.
    node.scrollTop = readPosition(currentKey) ?? 0;
    revealActive(node);
  }

  function onScroll() {
    writePosition(currentKey, node.scrollTop);
  }

  restore();
  node.addEventListener('scroll', onScroll, { passive: true });

  return {
    update(nextKey) {
      if (nextKey === currentKey) return;
      currentKey = nextKey;
      restore();
    },
    destroy() {
      node.removeEventListener('scroll', onScroll);
    },
  };
}

export function resetSidebarScrollMemory() {
  positions.clear();
}
