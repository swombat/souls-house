// Which messages voice mode should read aloud (VoiceModePanel): resident
// messages that have finished arriving since the panel opened, replies and
// progress notes alike, each once. `seen` starts with every message already
// on the page, so opening voice mode never reads out the backlog.
export function speakable(message) {
  return (
    message?.role === 'assistant' &&
    message.voice_available === true &&
    message.completed !== false &&
    !message.streaming &&
    Boolean(message.content?.trim())
  );
}

export function newReplies(messages, seen) {
  const ids = [];
  for (const message of messages || []) {
    if (seen.has(message.id) || !speakable(message)) continue;
    seen.add(message.id);
    ids.push(message.id);
  }
  return ids;
}

// Everything on the page when voice mode opens, except a resident message
// still arriving: that one is read when it completes.
export function initialSeen(messages) {
  return new Set(
    (messages || []).filter((m) => !(m.role === 'assistant' && (m.streaming || m.completed === false))).map((m) => m.id)
  );
}
