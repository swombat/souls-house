// The microphone side of voice mode: opens the mic, runs the turn detector on
// its samples, and streams each utterance out as it is spoken, resampled for
// the realtime transcriber: its opening (pre-roll), its frames, its end.
// Pure decisions (when a turn ends, how a WAV is written) live in
// voice-mode.js; this file is only the browser plumbing around them.
//
// Samples reach us through an AudioWorklet when the browser has one (every
// current browser, including iOS Safari) and a ScriptProcessorNode otherwise.
// The worklet module is tiny and built from a string, so no extra asset.
import { createTurnDetector, resample } from '$lib/voice-mode';

const DEFAULT_OUTPUT_RATE = 24_000;

const WORKLET_SOURCE = `
class VoiceModeTap extends AudioWorkletProcessor {
  process(inputs) {
    const channel = inputs[0] && inputs[0][0];
    if (channel && channel.length) this.port.postMessage(channel.slice());
    return true;
  }
}
registerProcessor('voice-mode-tap', VoiceModeTap);
`;

export function captureSupported(win = globalThis) {
  return Boolean(win.navigator?.mediaDevices?.getUserMedia && (win.AudioContext || win.webkitAudioContext));
}

// Starts listening. Resolves to a handle once the microphone is open.
//   onlevel(rms, threshold)       a few times a second, for the meter
//   onspeechstart(samples)        an utterance began; samples are its pre-roll
//   onaudio(samples)              a frame of the open utterance
//   onturn(durationMs)            the utterance ended
//   ondiscard(durationMs)         the burst was too short to be speech
//   oninterrupt(reason)           the browser stopped the audio: 'muted' (the
//                                 system took the mic track), 'ended' (the track
//                                 is gone and the mic must be reopened),
//                                 'suspended' (the audio context stopped)
//   onrestore()                   the track was unmuted or the context runs again
// All samples are mono Float32 at `outputRate`.
// The handle: mute(on) keeps the mic open but feeds silence to the detector
// (nothing is sent while muted); flush() ends the current utterance now;
// resume() asks a suspended context to run again; `alive` is false once the
// track has ended (reopen with a new capture); stop() ends any open utterance
// and closes everything.
export async function startCapture({
  onlevel,
  onspeechstart,
  onaudio,
  onturn,
  ondiscard,
  oninterrupt,
  onrestore,
  outputRate = DEFAULT_OUTPUT_RATE,
  detectorOptions = {},
} = {}) {
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
  });
  const track = stream.getAudioTracks?.()[0] ?? stream.getTracks()[0];
  // From here the microphone is ours. Anything below that fails must give it
  // back: the caller never receives a handle it could stop.
  let context = null;
  let source = null;
  let node = null;
  let workletUrl = null;
  const release = async () => {
    try {
      source?.disconnect();
      node?.disconnect();
      if (node?.port) node.port.onmessage = null;
      if (track) track.onmute = track.onunmute = track.onended = null;
      if (context) context.onstatechange = null;
    } catch {
      // already gone
    }
    stream.getTracks().forEach((track) => track.stop());
    if (workletUrl) URL.revokeObjectURL(workletUrl);
    try {
      await context?.close?.();
    } catch {
      // already closed
    }
  };

  let muted = false;
  let stopped = false;
  let lastLevelAt = 0;
  let detector;
  let out;

  function emit(events) {
    for (const event of events) {
      if (event.type === 'start') onspeechstart?.(out(event.samples));
      else if (event.type === 'audio') onaudio?.(out(event.samples));
      else if (event.type === 'discard') ondiscard?.(event.durationMs);
      else if (event.type === 'end') onturn?.(event.durationMs);
    }
  }

  function handle(samples) {
    if (stopped) return;
    if (muted) samples = new Float32Array(samples.length);
    emit(detector.feed(samples));
    const now = performance.now();
    if (now - lastLevelAt > 80) {
      lastLevelAt = now;
      onlevel?.(detector.level, detector.threshold);
    }
  }

  try {
    const Context = globalThis.AudioContext || globalThis.webkitAudioContext;
    context = new Context();
    // iOS leaves a fresh context suspended until a gesture has happened; the tap
    // that opened voice mode counts, but only if we ask.
    if (context.state === 'suspended') await context.resume().catch(() => {});

    detector = createTurnDetector({ sampleRate: context.sampleRate, ...detectorOptions, streamFrames: true });
    out = (samples) => resample(samples, context.sampleRate, outputRate);

    // Android mutes the track or suspends the context when the screen goes off
    // or another app takes the mic (jMapOj). Say so; the panel decides.
    if (track) {
      track.onmute = () => !stopped && oninterrupt?.('muted');
      track.onunmute = () => !stopped && onrestore?.();
      track.onended = () => !stopped && oninterrupt?.('ended');
    }
    context.onstatechange = () => {
      if (stopped) return;
      if (context.state === 'running') onrestore?.();
      else if (context.state !== 'closed') oninterrupt?.('suspended');
    };

    source = context.createMediaStreamSource(stream);
    if (context.audioWorklet) {
      workletUrl = URL.createObjectURL(new Blob([WORKLET_SOURCE], { type: 'application/javascript' }));
      await context.audioWorklet.addModule(workletUrl);
      node = new AudioWorkletNode(context, 'voice-mode-tap', { numberOfOutputs: 0 });
      node.port.onmessage = (event) => handle(event.data);
      source.connect(node);
    } else {
      node = context.createScriptProcessor(4096, 1, 1);
      node.onaudioprocess = (event) => handle(event.inputBuffer.getChannelData(0).slice());
      source.connect(node);
      // A ScriptProcessorNode only runs while connected to the destination.
      node.connect(context.destination);
    }
  } catch (error) {
    stopped = true;
    await release();
    throw error;
  }

  return {
    get muted() {
      return muted;
    },
    mute(on) {
      muted = Boolean(on);
      if (muted) emit(detector.flush());
    },
    flush() {
      emit(detector.flush());
    },
    get alive() {
      return !stopped && (!track || track.readyState !== 'ended');
    },
    get running() {
      return !stopped && context?.state === 'running' && !track?.muted;
    },
    async resume() {
      if (stopped || !context || context.state === 'running') return;
      await context.resume().catch(() => {});
    },
    async stop() {
      if (stopped) return;
      stopped = true;
      emit(detector.flush());
      await release();
    },
  };
}
