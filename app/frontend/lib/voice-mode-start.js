// Voice mode from New Chat (YMaddY): the wave on the New Chat page creates the
// conversation, and voice mode opens on the conversation page that loads next.
// The intent crosses the page change in memory, not in the URL, so it is one
// tap's worth: a reload, a shared link or the back button never opens the
// microphone by itself, and an intent nobody claims lapses after a short while.

const LAPSE_MS = 30_000;
let armedAt = null;

export function armVoiceStart(now = Date.now()) {
  armedAt = now;
}

export function disarmVoiceStart() {
  armedAt = null;
}

// True once, for the first conversation composer that asks within LAPSE_MS.
export function takeVoiceStart(now = Date.now()) {
  const armed = armedAt !== null && now - armedAt <= LAPSE_MS;
  armedAt = null;
  return armed;
}
