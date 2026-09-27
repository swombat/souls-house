export const DEFAULT_SCROLL_THRESHOLD = 200;

export function combinePaginatedMessages(olderMessages = [], recentMessages = []) {
  const recentIds = new Set(recentMessages.map((message) => message.id));
  const seen = new Set(recentIds);

  const uniqueOlderMessages = olderMessages.filter((message) => {
    if (seen.has(message.id)) return false;
    seen.add(message.id);
    return true;
  });

  return [...uniqueOlderMessages, ...recentMessages];
}

export function shouldLoadMoreMessages(
  { scrollTop, hasMore, loadingMore, oldestId },
  threshold = DEFAULT_SCROLL_THRESHOLD
) {
  return scrollTop < threshold && Boolean(hasMore) && !loadingMore && Boolean(oldestId);
}

export function prependOlderMessages({ olderMessages = [], newMessages = [], hasMore, oldestId }) {
  return {
    olderMessages: combinePaginatedMessages(newMessages, olderMessages),
    hasMore,
    oldestId,
  };
}

export function preserveDisplacedRecentMessages({
  olderMessages = [],
  previousRecentMessages = [],
  recentMessages = [],
}) {
  if (previousRecentMessages.length === 0) return olderMessages;

  if (recentMessages.length === 0) return olderMessages.length ? [] : olderMessages;
  const currentIds = new Set(recentMessages.map((message) => message.id));
  const overlap = previousRecentMessages.findIndex((message) => currentIds.has(message.id));
  // Only records before the surviving window were pushed out by new arrivals.
  // A missing record inside that window was deleted, not paginated away.
  const boundary = overlap < 0 ? previousRecentMessages.length : overlap;
  const displacedMessages = previousRecentMessages.slice(0, boundary).filter((message) => !currentIds.has(message.id));
  const deletedIds = new Set(
    previousRecentMessages
      .slice(boundary)
      .filter((message) => !currentIds.has(message.id))
      .map((message) => message.id)
  );
  if (displacedMessages.length === 0 && !olderMessages.some((message) => deletedIds.has(message.id)))
    return olderMessages;
  return combinePaginatedMessages(
    olderMessages.filter((message) => !deletedIds.has(message.id)),
    displacedMessages
  );
}
