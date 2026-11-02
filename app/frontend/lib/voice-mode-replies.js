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
// including replies still arriving, and so is every resident run that has a
// message on the page: a later message from that run (its final reply after a
// progress note) stays silent too. A message with no run provenance is
// superseded by its own id only; a run that had posted nothing when the person
// spoke is not known to be superseded and is read.
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
// The runtime run a resident message came from, when the message says.
const runOf = (m) => m.runtime_interaction_id ?? m.progress_run_id ?? null;
const time = (m) => {
  const t = Date.parse(m?.created_at);
  return Number.isNaN(t) ? null : t;
};

export function createReplyPicker(initial = []) {
  const opened = Math.max(-Infinity, ...initial.map(time).filter((t) => t !== null));
  const allowed = new Set(initial.filter(arriving).map((m) => m.id));
  const seen = new Set();
  const supersededRuns = new Set();
  let held = false;
  const supersede = (messages) => {
    for (const message of messages || []) {
      seen.add(message.id);
      if (message.role === 'assistant' && runOf(message) !== null) supersededRuns.add(runOf(message));
    }
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
        if (supersededRuns.has(runOf(message))) continue;
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
