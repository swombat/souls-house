import { writable, get } from 'svelte/store';
import { encodeWav } from '$lib/voice-mode';
import phononVoices from '$lib/phonon-voices.json';

// Phonon, the default voice engine (SpeechEngine, jEDyze): Gradium's 31M
// English model run in this browser on WebGPU by blixt's phonon-webgpu, pinned
// in package.json and patched to fetch its files from /phonon-assets on this
// site (bin/phonon-assets). The library keeps the files in Cache Storage
// ("phonon-webgpu", keyed by URLs that carry the pinned revisions), so a later
// visit or refresh loads from the browser; clearing the site's data, or the
// browser evicting it, means downloading them again. We ask for persistent
// storage to make eviction less likely; the browser may say no.
//
// One model per page, loaded on first use. No fallback: without WebGPU, or if
// the download or the GPU fails, the state says why and speech fails with that
// reason. The library's own CPU tier is not used (backend 'webgpu').

export const PHONON_MODEL = 'phonon-31m-en';
export const PHONON_SAMPLE_RATE = 24000;
export const DEFAULT_VOICE_NAME = 'Delia';
export const voices = phononVoices;

// { status: 'idle' | 'downloading' | 'initialising' | 'ready' | 'error',
//   progress: 0-100 while downloading, error: what to tell the person,
//   persisted: true/false once the browser has answered, null before }
export const phononState = writable({ status: 'idle', progress: 0, error: null, persisted: null });

export class PhononError extends Error {
  constructor(message, { cause, kind = 'failed' } = {}) {
    super(message, { cause });
    this.name = 'PhononError';
    this.kind = kind;
  }
}

const NO_WEBGPU =
  "This browser can't run Phonon, the voice engine: it needs WebGPU, which this browser doesn't offer (or has turned off). Try a recent Chrome, Edge or Safari.";

// What the person is told for a failure, by its cause.
export function describeFailure(error) {
  const message = String(error?.message || error || '');
  if (error?.name === 'AbortError') return { kind: 'aborted', message: 'Stopped.' };
  if (/no WebGPU/i.test(message)) return { kind: 'no_webgpu', message: NO_WEBGPU };
  if (/could not download/i.test(message) || /Failed to fetch|NetworkError|Load failed/i.test(message)) {
    const status = message.match(/\((\d{3})\)/)?.[1];
    return {
      kind: 'download',
      message: `Phonon's voice files didn't download (${status ? `HTTP ${status}` : 'network error'}). Check the connection and try again.`,
    };
  }
  if (/device|lost/i.test(message))
    return { kind: 'device_lost', message: 'The graphics device Phonon was using went away. Try again to reload it.' };
  return { kind: 'failed', message: `Phonon couldn't speak: ${message || 'unknown error'}.` };
}

export function voiceFor(id) {
  return (
    voices.find((voice) => voice.id === id) || voices.find((voice) => voice.name === DEFAULT_VOICE_NAME) || voices[0]
  );
}

let persistAsked = false;
async function requestPersistence(storage) {
  if (persistAsked) return;
  persistAsked = true;
  try {
    const persisted = (await storage?.persisted?.()) || (await storage?.persist?.());
    phononState.update((s) => ({ ...s, persisted: Boolean(persisted) }));
  } catch {
    phononState.update((s) => ({ ...s, persisted: false }));
  }
}

let model = null;
let loading = null;

// Resolves to the loaded model; rejects with a PhononError. A failed load is
// forgotten, so the next request tries again.
export function loadPhonon({
  importer = () => import('phonon-webgpu'),
  gpu = typeof navigator !== 'undefined' ? navigator.gpu : undefined,
  storage = typeof navigator !== 'undefined' ? navigator.storage : undefined,
} = {}) {
  if (model) return Promise.resolve(model);
  if (loading) return loading;
  if (!gpu) {
    const failure = new PhononError(NO_WEBGPU, { kind: 'no_webgpu' });
    phononState.update((s) => ({ ...s, status: 'error', error: failure.message }));
    return Promise.reject(failure);
  }
  requestPersistence(storage);
  phononState.update((s) => ({ ...s, status: 'initialising', progress: 0, error: null }));
  loading = (async () => {
    const { Phonon } = await importer();
    const loaded = await Phonon.load({
      model: PHONON_MODEL,
      backend: 'webgpu',
      progress: (percent) =>
        phononState.update((s) => ({
          ...s,
          status: percent < 100 ? 'downloading' : 'initialising',
          progress: percent,
        })),
    });
    model = loaded;
    loading = null;
    loaded.lost?.then?.(() => {
      if (model !== loaded) return;
      model = null;
      phononState.update((s) => ({
        ...s,
        status: 'error',
        error: 'The graphics device Phonon was using went away. It will reload the next time something is read aloud.',
      }));
    });
    phononState.update((s) => ({ ...s, status: 'ready', progress: 100, error: null }));
    return loaded;
  })().catch((error) => {
    loading = null;
    const { kind, message } = describeFailure(error);
    phononState.update((s) => ({ ...s, status: 'error', error: message }));
    throw new PhononError(message, { cause: error, kind });
  });
  return loading;
}

// Speaks text in a voice and resolves to { blob, duration } (a WAV). Aborting
// the signal stops the synthesis itself. Rejects with a PhononError.
// onAudio(samples, sampleRate), when given, hears each chunk as soon as it is
// made (YNwVle: Listen plays while the rest is still being made); the WAV is
// those same chunks joined.
export async function synthesize(text, { voice, signal, onAudio, load = loadPhonon } = {}) {
  const tts = await load();
  signal?.throwIfAborted?.();
  try {
    const { audio, sampleRate } = await tts.speak(text, {
      voice: voiceFor(voice).id,
      signal,
      ...(onAudio ? { onAudio: (samples) => onAudio(samples, PHONON_SAMPLE_RATE) } : {}),
    });
    return { blob: encodeWav(audio, sampleRate), duration: audio.length / sampleRate };
  } catch (error) {
    if (error instanceof PhononError) throw error;
    const { kind, message } = describeFailure(error);
    throw new PhononError(message, { cause: error, kind });
  }
}

export function phononStatus() {
  return get(phononState);
}

// Tests only: forget the loaded model and state.
export function resetPhononForTests() {
  model = null;
  loading = null;
  persistAsked = false;
  phononState.set({ status: 'idle', progress: 0, error: null, persisted: null });
}
