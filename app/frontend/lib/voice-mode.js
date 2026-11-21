// Voice mode in a conversation (planned in YgDwre, built in YMaddY): the person
// speaks, each finished utterance becomes an ordinary human message, and the
// residents' replies are read aloud. This file is the part that needs no
// browser: the turn detector that decides when an utterance has ended, the WAV
// encoder for the segment that is sent to transcription, and the release
// phrase. The browser glue (microphone, AudioContext) is in voice-mode-capture.js.

// Turn detection by energy, with an adaptive noise floor. Frames of PCM samples
// (mono, any rate) come in through feed(chunk, sound); events come out:
//   { type: 'start', level, threshold, barge }
//                                          speech began; level is the mean of the
//                                          frames that proved it, threshold the bar
//                                          they beat, barge true when a reply was
//                                          being heard
//   { type: 'end', samples, durationMs }   speech ended: the utterance with `preRollMs`
//                                          of audio before its first frame
//   { type: 'discard', durationMs }        a burst shorter than `minSpeechMs` (a cough, a door)
// With `streamFrames`, for a transcriber that listens while the person speaks:
//   'start' also carries `samples`, the pre-roll and the frames that proved it,
//   and every later frame of the turn arrives at once as { type: 'audio', samples }.
// Silence is `silenceMs` of frames below the threshold. The threshold is the
// larger of an absolute floor and a multiple of the running noise level, which
// is learnt from the quiet frames, so a noisy street raises it and a quiet room
// lowers it. A pause mid-thought longer than `silenceMs` ends the turn, and the
// person can finish in the next one. 2.8 s (JOyaQe): in a phone test on 20 Nov
// a slower speaker was cut mid-sentence twice by pauses of about 1.9 s in a
// quiet room, with 1.8 s here. A resident's reply takes ten seconds or more,
// so a brisk speaker loses about a second and a slow one keeps the end of the
// sentence. It was 1.8 s for walking outdoors (#756), where Daniel found 2–3 s
// before the transcript acceptable. Fixed, not learnt per speaker: one phone
// is often two people.
//
// Barge-in (YXDkBY). `sound` is the player's word on what is leaving the
// speaker right now: { playing, level }, where playing is true only while
// samples are actually being rendered (not while a reply is being made,
// queued, buffering or paused), and level is the RMS of the reply's own
// samples at that moment, or null when the player can't read them (a reply
// replayed through the audio element). While nothing plays, a turn starts as
// above. While a reply plays the microphone also hears it, however well the
// phone cancels it, and starting a turn pauses the reply, so then:
//   - With a level, the echo is predicted from the reply itself: `coupling`
//     times the loudest reply level of the last `echoLagMs` (the way from the
//     speaker to the mic takes time). A frame is a person's when it is over
//     `bargeRatio` times that prediction (and over the start bar). The
//     coupling is learnt from frames that turned out to be the reply, and
//     forgotten at every playback start, so one reply's echo never sets the
//     bar for the next.
//   - Before the coupling has anything to go on, there is no warm-up and no
//     blind interval: a candidate opens on the start bar at once, and its own
//     frames give the coupling (their median ratio to the reply's level). The
//     reply's echo follows the reply into its dips between words; a person's
//     voice does not. So a "wait" over the very first word proves itself in the
//     reply's first dip, and leakage, however loud, never does.
//   - Without a level, the bar is `bargeRatio` times the echo heard so far in
//     this playback (rising fast, falling slowly), and the start bar before
//     any of it, and proof takes `bargeAttackMs`. That path cannot tell
//     leakage from a person at onset.
// A candidate proves itself with `bargeProofMs` of person frames within
// `bargeWindowMs`; it is dropped, and its frames learnt as the reply, after
// `bargeGapMs` under the start bar or when the window runs out. The turn it
// starts keeps the whole candidate, so the first word is not lost.
export function createTurnDetector({
  sampleRate,
  frameMs = 20,
  attackMs = 60,
  silenceMs = 2800,
  minSpeechMs = 300,
  preRollMs = 300,
  floor = 0.012,
  noiseRatio = 3,
  maxTurnMs = 90_000,
  streamFrames = false,
  bargeRatio = 2,
  bargeProofMs = 60,
  bargeAttackMs = 300,
  bargeWindowMs = 1500,
  bargeGapMs = 100,
  echoLagMs = 60,
  minCouplingMs = 200,
  echoRise = 0.1,
  echoFall = 0.002,
} = {}) {
  if (!sampleRate) throw new Error('createTurnDetector needs a sampleRate');
  const frameSamples = Math.max(1, Math.round((sampleRate * frameMs) / 1000));
  const attackFrames = Math.max(1, Math.round(attackMs / frameMs));
  const silenceFrames = Math.max(1, Math.round(silenceMs / frameMs));
  const preRollFrames = Math.max(0, Math.round(preRollMs / frameMs));
  const proofFrames = Math.max(1, Math.round(bargeProofMs / frameMs));
  const blindProofFrames = Math.max(1, Math.round(bargeAttackMs / frameMs));
  const windowFrames = Math.max(proofFrames, Math.round(bargeWindowMs / frameMs));
  const gapFrames = Math.max(1, Math.round(bargeGapMs / frameMs));
  const lagFrames = Math.max(1, Math.round(echoLagMs / frameMs) + 1);
  const minCouplingFrames = Math.max(1, Math.round(minCouplingMs / frameMs));

  let noise = floor;
  let pending = new Float32Array(0);
  // Frames heard before a turn, newest last. Only the `preRollFrames` before
  // the frames that prove a start are kept with it.
  let history = [];
  const energyOf = new WeakMap(); // each frame's RMS, for counting a turn's speech
  let speaking = false;
  let loudRun = 0;
  let loudSum = 0;
  let quietRun = 0;
  let turn = [];
  let turnFrames = 0;
  let level = 0;
  // Per playback (reset whenever sound starts or stops).
  let playing = false;
  let recent = [];
  let coupling = 0;
  let couplingFrames = 0;
  let echo = 0;
  let echoFrames = 0;
  let candidate = null;
  // Frames left of the echo tail after the sound stops (the lag window): the
  // room still holds the reply's last syllable for that long.
  let tail = 0;

  const startBar = () => Math.max(floor, noise * noiseRatio);

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

  // The last `n` items, and none when n is 0 (slice(-0) is the whole array).
  const last = (items, n) => (n > 0 ? items.slice(-n) : []);

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

  // A turn opens on `proof` (the frames that proved it, oldest first) with the
  // pre-roll heard before them.
  function begin(before, proof, events, { level: proofLevel, threshold, barge, counted }) {
    speaking = true;
    quietRun = 0;
    loudRun = 0;
    loudSum = 0;
    candidate = null;
    const kept = last(before, preRollFrames);
    turn = [...kept, ...proof];
    history = [];
    // Speech just before the proof, unbroken up to it, is part of the turn's
    // speech too: a "wait" whose first syllables were under the reply's
    // predicted echo, or a word that began in the echo tail.
    let lead = 0;
    for (let i = kept.length - 1; i >= 0 && (energyOf.get(kept[i]) ?? 0) > startBar(); i -= 1) lead += 1;
    turnFrames = counted + lead;
    const start = { type: 'start', level: proofLevel, threshold, barge };
    if (streamFrames) start.samples = concat(turn);
    events.push(start);
  }

  function remember(frame) {
    history.push(frame);
    if (history.length > preRollFrames + attackFrames) history.shift();
  }

  function resetPlayback(next) {
    playing = next;
    tail = 0;
    recent = [];
    coupling = 0;
    couplingFrames = 0;
    echo = 0;
    echoFrames = 0;
    // A candidate in progress when sound starts or stops is dropped; its
    // frames stay in the history as ordinary sound.
    if (candidate) for (const frame of candidate.frames) remember(frame);
    candidate = null;
    loudRun = 0;
    loudSum = 0;
  }

  function learnEcho(energy) {
    const rate = echoFrames === 0 ? 1 : energy > echo ? echoRise : echoFall;
    echo = echo * (1 - rate) + energy * rate;
    echoFrames += 1;
  }

  // Frames that turned out to be the reply teach the coupling: the largest
  // ratio of what the mic heard to what the reply was playing, falling slowly
  // so one loud syllable is not forgotten in the next pause.
  function learnReply(energy, reference) {
    if (reference === null) return learnEcho(energy);
    if (reference <= 0 || energy <= 0) return;
    const ratio = energy / reference;
    // Rising at echoRise, not in one jump, so the frames of a person who
    // stayed under the bar can't ratchet it up on their own.
    if (couplingFrames === 0) coupling = ratio;
    else coupling = coupling * (1 - (ratio > coupling ? echoRise : echoFall)) + ratio * (ratio > coupling ? echoRise : echoFall);
    couplingFrames += 1;
  }

  function median(values) {
    if (!values.length) return 0;
    const sorted = [...values].sort((a, b) => a - b);
    return sorted[Math.floor(sorted.length / 2)];
  }

  // The coupling a candidate is judged by: what this playback has learnt,
  // and before that (or if the reply got louder in the mic) the candidate's
  // own median ratio, over its frames where the reply was at least half as
  // loud as its loudest.
  function couplingFor(c) {
    const peak = Math.max(...c.references, 0);
    const ratios = [];
    c.energies.forEach((energy, i) => {
      const reference = c.references[i];
      if (reference > 0 && reference >= peak / 2) ratios.push(energy / reference);
    });
    return Math.max(couplingFrames >= minCouplingFrames ? coupling : 0, median(ratios));
  }

  function barFor(reference, k) {
    if (reference === null) return Math.max(startBar(), echoFrames ? echo * bargeRatio : 0);
    return Math.max(startBar(), bargeRatio * k * reference);
  }

  function playbackFrame(frame, energy, soundLevel, events) {
    const hasLevel = typeof soundLevel === 'number' && Number.isFinite(soundLevel);
    recent.push(hasLevel ? soundLevel : 0);
    if (recent.length > lagFrames) recent.shift();
    const reference = hasLevel ? Math.max(...recent) : null;

    if (!candidate) {
      const k = couplingFrames >= minCouplingFrames ? coupling : 0;
      // With a level, a candidate opens on the start bar and is judged once
      // its frames say what the reply sounds like in the mic; frames under
      // the learnt prediction are the reply and are not candidates at all.
      const over = reference === null ? energy > barFor(null) : energy > startBar() && energy > bargeRatio * k * reference;
      if (!over) {
        learnReply(energy, reference);
        remember(frame);
        return;
      }
      candidate = { before: history.slice(), frames: [], energies: [], references: [], quiet: 0 };
    }

    const c = candidate;
    c.frames.push(frame);
    c.energies.push(energy);
    c.references.push(reference === null ? -1 : reference);
    c.quiet = energy > startBar() ? 0 : c.quiet + 1;

    const k = reference === null ? 0 : couplingFor(c);
    let proofs = 0;
    let sum = 0;
    let threshold = startBar();
    c.energies.forEach((e, i) => {
      const r = c.references[i];
      const bar = r < 0 ? barFor(null) : barFor(r, k);
      if (e > bar) {
        proofs += 1;
        sum += e;
        threshold = Math.max(threshold, bar);
      }
    });
    if (proofs >= (reference === null ? blindProofFrames : proofFrames)) {
      // What counts toward minSpeechMs: the candidate's frames over the start
      // bar from the start of the unbroken run that holds its first proof. A
      // "wait" over a word is all of its frames; a cough in a gap between the
      // reply's words is only itself, so it is still discarded.
      const bars = c.energies.map((e, i) => (c.references[i] < 0 ? barFor(null) : barFor(c.references[i], k)));
      let first = c.energies.findIndex((e, i) => e > bars[i]);
      while (first > 0 && c.energies[first - 1] > startBar()) first -= 1;
      const counted = c.energies.slice(first).filter((e) => e > startBar()).length;
      begin(c.before, c.frames, events, { level: sum / proofs, threshold, barge: true, counted });
      return;
    }
    if (c.quiet >= gapFrames || c.frames.length >= windowFrames) {
      candidate = null;
      // Learnt as the reply, but only its frames at or under the candidate's
      // own median ratio: a person who didn't prove themselves (a "wait"
      // with no gap in the reply under it) must not raise the bar for the
      // next try.
      const k = c.references.some((r) => r >= 0) ? couplingFor(c) : Infinity;
      c.energies.forEach((e, i) => {
        const r = c.references[i];
        if (r < 0) learnReply(e, null);
        else if (r === 0 || e <= k * r) learnReply(e, r);
      });
      for (const f of c.frames) remember(f);
    }
  }

  function frameIn(frame, energy, sound, events) {
    level = energy;

    if (!speaking) {
      const nowPlaying = Boolean(sound?.playing);
      if (nowPlaying && (!playing || tail > 0)) resetPlayback(true); // a new start, even mid-tail
      else if (!nowPlaying && playing && tail === 0) tail = lagFrames + 1; // the sound just stopped
      if (playing && tail > 0) {
        tail -= 1;
        if (tail === 0) resetPlayback(false);
        else return playbackFrame(frame, energy, 0, events);
      }
      if (playing) return playbackFrame(frame, energy, sound.level, events);

      const threshold = startBar();
      const loud = energy > threshold;
      // Learn the room from quiet frames only, slowly down and faster up.
      if (!loud) noise = energy < noise ? noise * 0.95 + energy * 0.05 : noise * 0.8 + energy * 0.2;
      remember(frame);
      loudRun = loud ? loudRun + 1 : 0;
      loudSum = loud ? loudSum + energy : 0;
      if (loudRun >= attackFrames) {
        const proof = history.slice(-attackFrames);
        const before = history.slice(0, history.length - attackFrames);
        begin(before, proof, events, { level: loudSum / loudRun, threshold, barge: false, counted: 0 });
      }
      return;
    }

    // A turn that opened while sound played forgets that playback: the
    // player pauses the reply, and the next sound is a new start.
    if (playing && !sound?.playing) resetPlayback(false);
    turn.push(frame);
    if (streamFrames) events.push({ type: 'audio', samples: frame.slice() });
    if (energy > startBar()) {
      turnFrames += 1;
      quietRun = 0;
    } else {
      quietRun += 1;
    }
    if (quietRun >= silenceFrames || turn.length * frameMs >= maxTurnMs) finish(events);
  }

  return {
    // Returns the events this chunk produced, oldest first. `sound` is the
    // player's { playing, level } while this chunk was heard (see above).
    feed(chunk, sound = null) {
      const events = [];
      let buffer = pending.length ? concat([pending, chunk]) : chunk;
      let offset = 0;
      while (buffer.length - offset >= frameSamples) {
        const frame = buffer.subarray(offset, offset + frameSamples);
        const energy = rms(frame);
        energyOf.set(frame, energy);
        frameIn(frame, energy, sound, events);
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
      return startBar();
    },
    // What this playback has learnt (0 before anything): mic level per unit
    // of reply level, and the echo level when the player gives no level.
    get coupling() {
      return couplingFrames ? coupling : 0;
    },
    get echo() {
      return echo;
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
// 'suspended' when the audio engine stopped, 'reopen' when reopening it after a
// device change failed). It outranks every phase but the
// first two: nothing is being heard, whatever the phase says.
// Idle (nothing being heard, nothing being read): not "Listening", which
// sounds like recording and like the person's turn is still open. It says the
// room is theirs to speak again (Daniel, jNwAdJ ezmgrw, clarified eBVREL:
// "it should say something like, speak again to say something else").
export const PAUSED_STATUS = {
  hidden: 'Paused: the screen went off. Open the page again to carry on.',
  muted: 'Paused: the system took the microphone. It resumes when it gives it back.',
  suspended: 'Paused: the browser stopped the audio. Open the page again to carry on.',
  reopen: 'Paused: the microphone could not be reopened. Open the page again to carry on.',
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
