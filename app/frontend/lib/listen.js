import { get, writable } from 'svelte/store';
import { createSpeechSource } from '$lib/speech-source';

// Listen on resident messages (SpeechEngine, jEDyze), owned by the page, not
// by the message objects: a message refresh replaces those, and must not drop
// a reply being made or a player already playing. State per message id:
// { status: 'loading' | 'ready' | 'pending' | 'error', url, error }.
// - ready: Phonon made the audio here; url is a blob URL this module keeps
//   until reset, so a player holding it never loses it;
// - pending: ElevenLabs is making the stored audio; the message's own
//   voice_audio_url shows it when the refresh brings it;
// - error: the reason, never the other engine.
// reset() (engine change, leaving the conversation) aborts what is being made,
// ignores anything that finishes later, and releases every URL, so no old
// audio plays on. Players unmount with their state.

export const listenState = writable({});

let source = createSpeechSource({ mode: 'listen', keep: Infinity });
let generation = 0;
const inFlight = new Map();

function set(id, value) {
  listenState.update((state) => ({ ...state, [id]: value }));
}

// postVoice(id, { signal }) asks for ElevenLabs' stored audio (POST /voice)
// and resolves to { url } (already made), { pending: true }, or { error }.
export async function listen(id, { postVoice } = {}) {
  if (inFlight.has(id) || get(listenState)[id]?.status === 'ready') return;
  const mine = generation;
  const controller = new AbortController();
  inFlight.set(id, controller);
  const current = () => mine === generation;
  set(id, { status: 'loading' });
  try {
    const answer = await source.resolve(id, { signal: controller.signal });
    if (!current()) return;
    if (answer.engine === 'phonon') return set(id, { status: 'ready', url: answer.url });
    const result = (await postVoice?.(id, { signal: controller.signal })) || {};
    if (!current()) return;
    if (result.error) set(id, { status: 'error', error: result.error });
    else set(id, result.url ? { status: 'stored', url: result.url } : { status: 'pending' });
  } catch (error) {
    if (!current() || error?.name === 'AbortError') return;
    set(id, { status: 'error', error: error?.message || 'This message could not be read aloud.' });
  } finally {
    if (inFlight.get(id) === controller) inFlight.delete(id);
  }
}

export function resetListen() {
  generation += 1;
  inFlight.forEach((controller) => controller.abort());
  inFlight.clear();
  source.close();
  source = createSpeechSource({ mode: 'listen', keep: Infinity });
  listenState.set({});
}
