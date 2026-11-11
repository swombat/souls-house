import { get, writable } from 'svelte/store';
import { createSpeechSource } from '$lib/speech-source';
import { createStreamPlayer } from '$lib/stream-player';

// Listen on resident messages (SpeechEngine, jEDyze), owned by the page, not
// by the message objects: a message refresh replaces those, and must not drop
// a reply being made or a player already playing. State per message id:
// { status: 'loading' | 'streaming' | 'ready' | 'pending' | 'error', url, error }.
// - streaming: Phonon is making the audio and it plays as it is made
//   (YNwVle): `stream` is the player (lib/stream-player.js), made inside the
//   tap. Once everything is made, `url` is the kept WAV too; when the stream
//   has been heard to the end the message turns `ready` with `heard: true`,
//   and the ordinary player takes over for a replay without starting itself;
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
const streams = new Set();

// A stream player, or null where the browser has no Web Audio (then Listen
// waits for the whole message, as before).
export function defaultStream(options) {
  try {
    if (typeof globalThis.AudioContext !== 'function' && typeof globalThis.webkitAudioContext !== 'function')
      return null;
    return createStreamPlayer(options);
  } catch {
    return null;
  }
}

function set(id, value) {
  listenState.update((state) => ({ ...state, [id]: value }));
}

// postVoice(id, { signal }) asks for ElevenLabs' stored audio (POST /voice)
// and resolves to { url } (already made), { pending: true }, or { error }.
// Call it from the tap: the stream player's sound is allowed only from there.
export async function listen(id, { postVoice, stream = defaultStream } = {}) {
  const status = get(listenState)[id]?.status;
  if (inFlight.has(id) || status === 'ready' || status === 'streaming') return;
  const mine = generation;
  const controller = new AbortController();
  inFlight.set(id, controller);
  const current = () => mine === generation;
  let streaming = false;
  const player = stream({
    onended: () => {
      streams.delete(player);
      if (!current()) return;
      set(id, { status: 'ready', url: get(listenState)[id]?.url, heard: true });
    },
  });
  if (player) streams.add(player);
  const drop = () => {
    if (!player) return;
    streams.delete(player);
    player.stop();
  };
  const onAudio = player
    ? (samples, sampleRate) => {
        if (!current() || player.stopped) return;
        player.push(samples, sampleRate);
        if (streaming) return;
        streaming = true;
        set(id, { status: 'streaming', stream: player });
      }
    : undefined;
  set(id, { status: 'loading' });
  try {
    const answer = await source.resolve(id, { signal: controller.signal, ...(onAudio ? { onAudio } : {}) });
    if (!current()) return drop();
    if (answer.engine === 'phonon') {
      if (streaming && !player.stopped) {
        set(id, { status: 'streaming', stream: player, url: answer.url });
        return player.finish();
      }
      drop();
      return set(id, { status: 'ready', url: answer.url });
    }
    drop();
    const result = (await postVoice?.(id, { signal: controller.signal })) || {};
    if (!current()) return;
    if (result.error) set(id, { status: 'error', error: result.error });
    else set(id, result.url ? { status: 'stored', url: result.url } : { status: 'pending' });
  } catch (error) {
    drop();
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
  streams.forEach((player) => player.stop());
  streams.clear();
  source.close();
  source = createSpeechSource({ mode: 'listen', keep: Infinity });
  listenState.set({});
}
