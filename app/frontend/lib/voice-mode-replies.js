// Which messages voice mode should read aloud (VoiceModePanel): resident
// messages, replies and progress notes alike, that finished arriving after the
// panel opened, each once.
//
// "After the panel opened" is a boundary in server time: the newest created_at
// on the page at that moment. Older history loaded later by scrolling falls
// before it and is never read. A resident message still arriving at open is
// let through explicitly. Message ids are opaque, so they say nothing about order.
//
// When the person starts speaking, everything then on the page is superseded,
// including replies still arriving: interruption is final for them.
export function speakable(message) {
  return (
    message?.role === 'assistant' &&
    message.voice_available === true &&
    message.completed !== false &&
    !message.streaming &&
    Boolean(message.content?.trim())
  );
}

const arriving = (m) => m.role === 'assistant' && (m.streaming || m.completed === false);
const time = (m) => {
  const t = Date.parse(m?.created_at);
  return Number.isNaN(t) ? null : t;
};

export function createReplyPicker(initial = []) {
  const opened = Math.max(-Infinity, ...initial.map(time).filter((t) => t !== null));
  const allowed = new Set(initial.filter(arriving).map((m) => m.id));
  const seen = new Set();
  let held = false;
  const supersede = (messages) => {
    for (const message of messages || []) seen.add(message.id);
    allowed.clear();
  };

  return {
    // New ids to read, in page order; each is returned once. While the person
    // is speaking nothing is returned: what lands then is superseded too.
    take(messages) {
      if (held) {
        supersede(messages);
        return [];
      }
      const ids = [];
      for (const message of messages || []) {
        if (seen.has(message.id) || !speakable(message)) continue;
        seen.add(message.id);
        const t = time(message);
        if (allowed.has(message.id) || (t !== null && t > opened)) ids.push(message.id);
      }
      return ids;
    },
    // Speech started: nothing on the page now is read, even when it completes later.
    hold(messages) {
      held = true;
      supersede(messages);
    },
    // The person's turn ended (sent or discarded): later replies are read again.
    release() {
      held = false;
    },
  };
}
