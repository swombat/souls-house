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
// What happens to the replies on the page depends on how the burst ends (#748):
// - a committed turn supersedes everything then on the page, including replies
//   that landed while they spoke and replies still arriving, by id. A message
//   created after the commit is read, whatever run it belongs to (#755): a
//   resident turn that posts a progress note every ~20 s is one run, and
//   silencing the run silenced every later message of a long reply after one
//   barge-in.
// - a discarded burst (a cough, the dog, a door: sound the detector dropped as
//   not speech) supersedes nothing: what landed during it is read afterwards.
// Superseding at speech-start instead meant every noise in the room silently
// buried whatever had just arrived.
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
    // is speaking nothing is returned and nothing is marked: the turn decides.
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
    // Speech started: hold everything until the burst is committed or discarded.
    hold() {
      held = true;
    },
    // The person's turn was sent: nothing on the page now is read, even when it
    // completes later. Later replies are read again.
    commit(messages) {
      supersede(messages);
      held = false;
    },
    // The burst was not speech: nothing is superseded, and what landed during
    // it is read by the next take.
    discard() {
      held = false;
    },
  };
}
