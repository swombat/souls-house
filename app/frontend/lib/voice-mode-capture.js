// The microphone side of voice mode: opens the mic, runs the turn detector on
// its samples, and hands each finished utterance over as a 16 kHz WAV blob.
// Pure decisions (when a turn ends, how a WAV is written) live in
// voice-mode.js; this file is only the browser plumbing around them.
//
// Samples reach us through an AudioWorklet when the browser has one (every
// current browser, including iOS Safari) and a ScriptProcessorNode otherwise.
// The worklet module is tiny and built from a string, so no extra asset.
import { createTurnDetector, downsample, encodeWav } from '$lib/voice-mode';

const TARGET_RATE = 16_000;

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
//   onspeechstart()               the detector heard the start of an utterance
//   onturn(blob, durationMs)      an utterance ended; blob is a 16 kHz mono WAV
//   ondiscard(durationMs)         a burst too short to be speech
// The handle: mute(on) keeps the mic open but feeds silence to the detector
// (nothing is sent while muted); flush() ends the current utterance now;
// stop() closes everything and returns the final flushed utterance, if any.
export async function startCapture({ onlevel, onspeechstart, onturn, ondiscard, detectorOptions = {} } = {}) {
  const stream = await navigator.mediaDevices.getUserMedia({
    audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
  });
  const Context = globalThis.AudioContext || globalThis.webkitAudioContext;
  const context = new Context();
  // iOS leaves a fresh context suspended until a gesture has happened; the tap
  // that opened voice mode counts, but only if we ask.
  if (context.state === 'suspended') await context.resume().catch(() => {});

  const detector = createTurnDetector({ sampleRate: context.sampleRate, ...detectorOptions });
  let muted = false;
  let stopped = false;
  let lastLevelAt = 0;

  function emit(events) {
    for (const event of events) {
      if (event.type === 'start') onspeechstart?.();
      else if (event.type === 'discard') ondiscard?.(event.durationMs);
      else if (event.type === 'end') {
        const samples = downsample(event.samples, context.sampleRate, TARGET_RATE);
        onturn?.(encodeWav(samples, TARGET_RATE), event.durationMs);
      }
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

  const source = context.createMediaStreamSource(stream);
  let node;
  let workletUrl = null;
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
    async stop() {
      if (stopped) return;
      stopped = true;
      emit(detector.flush());
      try {
        source.disconnect();
        node.disconnect();
        if (node.port) node.port.onmessage = null;
      } catch {
        // already gone
      }
      stream.getTracks().forEach((track) => track.stop());
      if (workletUrl) URL.revokeObjectURL(workletUrl);
      await context.close().catch(() => {});
    },
  };
}
