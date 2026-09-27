// Use the full message sequence, not just visible speech: hidden/system posts
// still interrupt. No bodies are merged; every section retains its message ID.
export function progressMessageGroups(messages, visibleMessages = messages) {
  const visible = new Set(visibleMessages.map((message) => message.id));
  const groups = [];
  const seenRuns = new Set();
  let previous = null;
  for (const message of messages) {
    const key =
      message.progress_message && message.runtime_interaction_id && message.agent_id
        ? `${message.agent_id}:${message.runtime_interaction_id}`
        : null;
    if (!visible.has(message.id)) {
      previous = message;
      continue;
    }
    const group = groups.at(-1);
    if (
      key &&
      group?.runKey === key &&
      group.messages.at(-1) === previous &&
      !previous.progress_break_after &&
      group.messages.length < 20
    ) {
      group.messages.push(message);
    } else {
      groups.push({
        message,
        messages: [message],
        runKey: key,
        continued: Boolean(key && seenRuns.has(key)),
      });
    }
    if (key) seenRuns.add(key);
    previous = message;
  }
  const lastByRun = new Map();
  for (const group of groups) {
    if (group.runKey) lastByRun.set(group.runKey, group);
  }
  for (const group of groups) group.lastForRun = lastByRun.get(group.runKey) === group;
  return groups;
}

export function elapsedBetween(previous, current) {
  const gap = new Date(current).getTime() - new Date(previous).getTime();
  if (!Number.isFinite(gap) || gap < 0) return null;
  const seconds = Math.floor(gap / 1000);
  if (seconds < 60) return `${seconds}s elapsed`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ${String(seconds % 60).padStart(2, '0')}s elapsed`;
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m elapsed`;
}
