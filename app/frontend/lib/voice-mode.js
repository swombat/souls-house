// Voice mode in a conversation (planned in YgDwre, built in YMaddY): the person
// speaks, each finished utterance becomes an ordinary human message, and the
// residents' replies are read aloud. This file is the part that needs no
// browser: the turn detector that decides when an utterance has ended, the WAV
// encoder for the segment that is sent to transcription, and the release
// phrase. The browser glue (microphone, AudioContext) is in voice-mode-capture.js.

// Turn detection by energy, with an adaptive noise floor. Frames of PCM samples
// (mono, any rate) come in through feed(); events come out:
//   { type: 'start' }                      speech began (after `attackMs` of it)
//   { type: 'end', samples, durationMs }   speech ended: the utterance with `preRollMs`
//                                          of audio before its first frame
//   { type: 'discard', durationMs }        a burst shorter than `minSpeechMs` (a cough, a door)
// With `streamFrames`, for a transcriber that listens while the person speaks:
//   'start' also carries `samples`, the pre-roll and attack frames, and every
//   later frame of the turn arrives at once as { type: 'audio', samples }.
// Silence is `silenceMs` of frames below the threshold. The threshold is the
// larger of an absolute floor and a multiple of the running noise level, which
// is learnt from the quiet frames, so a noisy street raises it and a quiet room
// lowers it. Conservative on purpose: a pause mid-thought longer than
// `silenceMs` ends the turn, and the person can finish in the next one. 1.8 s,
// not 1.2 s (#756): walking outdoors, 1.2 s split sentences into separate
// messages, and each turn is now a voice note of its own; Daniel finds 2–3 s
// before the transcript acceptable.
export function createTurnDetector({
  sampleRate,
  frameMs = 20,
  attackMs = 60,
  silenceMs = 1800,
  minSpeechMs = 300,
  preRollMs = 300,
  floor = 0.012,
  noiseRatio = 3,
  maxTurnMs = 90_000,
  streamFrames = false,
} = {}) {
  if (!sampleRate) throw new Error('createTurnDetector needs a sampleRate');
  const frameSamples = Math.max(1, Math.round((sampleRate * frameMs) / 1000));
  const attackFrames = Math.max(1, Math.round(attackMs / frameMs));
  const silenceFrames = Math.max(1, Math.round(silenceMs / frameMs));
  const preRollFrames = Math.max(0, Math.round(preRollMs / frameMs));

  let noise = floor;
  let pending = new Float32Array(0);
  let preRoll = [];
  let speaking = false;
  let loudRun = 0;
  let quietRun = 0;
  let turn = [];
  let turnFrames = 0;
  let level = 0;

  function rms(frame) {
    let sum = 0;
    for (let i = 0; i < frame.length; i += 1) sum += frame[i] * frame[i];
    return Math.sqrt(sum / frame.length);
  }

  function concat(frames) {
    const out = new Float32Array(frames.reduce((n, f) => n + f.length, 0));
    let offset = 0;
    for (const frame of frames) {
      out.set(frame, offset);
      offset += frame.length;
    }
    return out;
  }

  function finish(events) {
    const durationMs = turnFrames * frameMs;
    const samples = concat(turn);
    turn = [];
    turnFrames = 0;
    speaking = false;
    loudRun = 0;
    quietRun = 0;
    if (durationMs < minSpeechMs) events.push({ type: 'discard', durationMs });
    else events.push({ type: 'end', samples, durationMs: Math.round((samples.length / sampleRate) * 1000) });
  }

  function frameIn(frame, events) {
    const energy = rms(frame);
    level = energy;
    const threshold = Math.max(floor, noise * noiseRatio);
    const loud = energy > threshold;

    if (!speaking) {
      // Learn the room from quiet frames only, slowly down and faster up.
      if (!loud) noise = energy < noise ? noise * 0.95 + energy * 0.05 : noise * 0.8 + energy * 0.2;
      preRoll.push(frame);
      if (preRoll.length > preRollFrames) preRoll.shift();
      loudRun = loud ? loudRun + 1 : 0;
      if (loudRun >= attackFrames) {
        speaking = true;
        quietRun = 0;
        turn = preRoll.slice();
        preRoll = [];
        turnFrames = 0;
        events.push(streamFrames ? { type: 'start', samples: concat(turn) } : { type: 'start' });
      }
      return;
    }

    turn.push(frame);
    if (streamFrames) events.push({ type: 'audio', samples: frame.slice() });
    if (loud) {
      turnFrames += 1;
      quietRun = 0;
    } else {
      quietRun += 1;
    }
    if (quietRun >= silenceFrames || turn.length * frameMs >= maxTurnMs) finish(events);
  }

  return {
    // Returns the events this chunk produced, oldest first.
    feed(chunk) {
      const events = [];
      let buffer = pending.length ? concat([pending, chunk]) : chunk;
      let offset = 0;
      while (buffer.length - offset >= frameSamples) {
        frameIn(buffer.subarray(offset, offset + frameSamples), events);
        offset += frameSamples;
      }
      pending = buffer.subarray(offset).slice();
      return events;
    },
    // Ends the current utterance now (the person pressed End, or a release phrase landed).
    flush() {
      const events = [];
      if (speaking) finish(events);
      return events;
    },
    get speaking() {
      return speaking;
    },
    // The last frame's RMS, for the level meter.
    get level() {
      return level;
    },
    get threshold() {
      return Math.max(floor, noise * noiseRatio);
    },
  };
}

// Linear-interpolation downsample to `toRate` (16 kHz for transcription keeps
// the upload small; speech has nothing above 8 kHz worth the bytes).
export function downsample(samples, fromRate, toRate) {
  if (fromRate === toRate) return samples;
  if (fromRate < toRate) throw new Error('downsample only lowers the rate');
  const ratio = fromRate / toRate;
  const length = Math.floor(samples.length / ratio);
  const out = new Float32Array(length);
  for (let i = 0; i < length; i += 1) {
    const position = i * ratio;
    const index = Math.floor(position);
    const next = Math.min(index + 1, samples.length - 1);
    const fraction = position - index;
    out[i] = samples[index] * (1 - fraction) + samples[next] * fraction;
  }
  return out;
}

// 16-bit PCM mono WAV, which every transcription service reads. The bytes are
// separate from the Blob so they can be checked without a browser.
export function encodeWavBytes(samples, sampleRate) {
  const buffer = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(buffer);
  const ascii = (offset, text) => {
    for (let i = 0; i < text.length; i += 1) view.setUint8(offset + i, text.charCodeAt(i));
  };
  ascii(0, 'RIFF');
  view.setUint32(4, 36 + samples.length * 2, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  ascii(36, 'data');
  view.setUint32(40, samples.length * 2, true);
  let offset = 44;
  for (let i = 0; i < samples.length; i += 1, offset += 2) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(offset, Math.round(clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff), true);
  }
  return buffer;
}

export function encodeWav(samples, sampleRate) {
  return new Blob([encodeWavBytes(samples, sampleRate)], { type: 'audio/wav' });
}

// Linear-interpolation resample in either direction. The realtime transcriber
// takes 24 kHz; a phone's context is usually 48 kHz, occasionally 16 kHz.
export function resample(samples, fromRate, toRate) {
  if (fromRate === toRate) return samples;
  const ratio = fromRate / toRate;
  const length = Math.floor(samples.length / ratio);
  const out = new Float32Array(length);
  for (let i = 0; i < length; i += 1) {
    const position = i * ratio;
    const index = Math.floor(position);
    const next = Math.min(index + 1, samples.length - 1);
    const fraction = position - index;
    out[i] = samples[index] * (1 - fraction) + samples[next] * fraction;
  }
  return out;
}

// Little-endian 16-bit PCM as base64, the realtime API's audio encoding.
export function pcm16Base64(samples) {
  const bytes = new Uint8Array(samples.length * 2);
  const view = new DataView(bytes.buffer);
  for (let i = 0; i < samples.length; i += 1) {
    const clamped = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(i * 2, Math.round(clamped < 0 ? clamped * 0x8000 : clamped * 0x7fff), true);
  }
  let binary = '';
  const step = 0x8000;
  for (let i = 0; i < bytes.length; i += step) binary += String.fromCharCode(...bytes.subarray(i, i + step));
  return btoa(binary);
}

// "Over to you" at the end of an utterance is the explicit hand-over. It is
// not part of what the person said; the transcript goes out without it. With
// transcription that arrives after the segment, the pause has already ended
// the turn, so the phrase only cleans the text; a streaming transcriber can
// also use `release` to commit early.
// Only a comma or space before the phrase is taken with it: the sentence's own
// closing punctuation ("…today? Over to you.") stays.
const RELEASE_PHRASES = [/[\s,]*\bover to you\b[\s,.!?]*$/i];

export function stripReleasePhrase(text) {
  const trimmed = (text ?? '').trim();
  for (const pattern of RELEASE_PHRASES) {
    if (pattern.test(trimmed)) return { text: trimmed.replace(pattern, '').trim(), release: true };
  }
  return { text: trimmed, release: false };
}

// The voice-mode panel's one-line status. Mute is separate from the phase: it
// stops what the microphone sends, whatever the earlier turns are still doing.
//
// paused: why the browser stopped the microphone ('hidden' when the screen went
// off or the page went to the back, 'muted' when the system took the mic,
// 'suspended' when the audio engine stopped). It outranks every phase but the
// first two: nothing is being heard, whatever the phase says.
// Idle (nothing being heard, nothing being read): not "Listening", which
// sounds like recording and like the person's turn is still open. It says the
// room is theirs to speak again (Daniel, jNwAdJ ezmgrw, clarified eBVREL:
// "it should say something like, speak again to say something else").
export const PAUSED_STATUS = {
  hidden: 'Paused: the screen went off. Open the page again to carry on.',
  muted: 'Paused: the system took the microphone. It resumes when it gives it back.',
  suspended: 'Paused: the browser stopped the audio. Open the page again to carry on.',
};

export function voiceModeStatus({ phase, muted, note, speaking, paused = null }) {
  if (phase === 'starting') return 'Opening the microphone…';
  if (phase === 'failed') return note || 'Voice mode could not start.';
  if (paused) return PAUSED_STATUS[paused] || PAUSED_STATUS.hidden;
  const hush = muted ? ' Muted: nothing new is sent.' : '';
  if (phase === 'transcribing') return `Transcribing…${hush}`;
  if (phase === 'sending') return `Sending…${hush}`;
  if (muted) return 'Muted. Nothing you say is sent.';
  if (phase === 'hearing') return 'Hearing you…';
  if (speaking) return 'Speaking. Talk to interrupt.';
  return 'Waiting for you. Speak again to say something else.';
}
