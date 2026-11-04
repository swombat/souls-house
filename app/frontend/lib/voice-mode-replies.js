// Which messages voice mode should read aloud (VoiceModePanel): resident
// messages, replies and progress notes alike, that finished arriving after the
// panel opened, each once.
//
// "After the panel opened" is a boundary in server time: the newest created_at
// on the page at that moment. Older history loaded later by scrolling falls
// before it and is never read. A resident message still arriving at open is
// let through explicitly. Message ids are opaque, so they say nothing about order.
//
// While the person is speaking nothing is read, and nothing is decided either.
// When the burst ends, whether it was sent as a turn or discarded as noise,
// nothing is superseded: what landed while they spoke is read afterwards, and a
// reply still arriving is read once it completes (#758: speaking over a reply
// never loses it, the same way a reply posted before five voice notes is still
// there to scroll up to). An earlier version superseded what was on the page at
// a sent turn (#749), then every run with a message on the page (#755/#757).
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

  return {
    // New ids to read, in page order; each is returned once. While the person
    // is speaking nothing is returned and nothing is marked.
    take(messages) {
      if (held) return [];
      const ids = [];
      for (const message of messages || []) {
        if (seen.has(message.id) || !speakable(message)) continue;
        seen.add(message.id);
        const t = time(message);
        if (allowed.has(message.id) || (t !== null && t > opened)) ids.push(message.id);
      }
      return ids;
    },
    // Speech started: hold everything until the burst ends.
    hold() {
      held = true;
    },
    // The burst ended (sent or discarded): what landed during it is read by the
    // next take.
    release() {
      held = false;
    },
  };
}
