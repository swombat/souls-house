// Phonon's speech made louder at the source (YGBxrJ). Measured on 20 Nov, its
// replies came out around -23 LUFS, as do the house's ElevenLabs replies: about
// 7 dB under what phones usually play apps at (around -16), and Daniel heard
// voice mode as "much lower than it should be" on his phone (YnwyBe, eGBNow).
//
// Every sample is raised by a fixed gain, and anything the gain would push
// past the knee is bent smoothly towards the ceiling instead of clipping.
// Measured on Zoey, Delia and Hugh (-23.2, -22.4, -20.8 LUFS before): after,
// -16.2, -15.4, -14.0 LUFS with true peaks of -1.1, -0.8, -0.7 dBTP. The
// ceiling bounds samples, not true peak: a saturated tone near 12 kHz can
// still overshoot between samples. Speech has not come near that. The
// shaping looks at one sample at a time and keeps no state, so a chunk shaped
// as it is made and the same samples shaped again once joined are identical:
// the streamed reply and its kept WAV (the replay) sound the same.
//
// What this cannot do: if the phone has moved the page to its call path (an
// open microphone with echo cancellation often does), the call volume governs
// it, and gain here only makes up part of that.

export const SPEECH_GAIN_DB = 7;
export const KNEE = 0.7; // about -3 dBFS: below this, samples are only scaled
export const CEILING = 0.92; // the bend approaches it; only absurd overloads reach it

const ROOM = CEILING - KNEE;

export function shapeSample(value, gain) {
  const raised = value * gain;
  const size = Math.abs(raised);
  if (size <= KNEE) return raised;
  // tanh leaves the knee with slope 1, so the bend has no corner.
  return Math.sign(raised) * (KNEE + ROOM * Math.tanh((size - KNEE) / ROOM));
}

// A new array: the samples Phonon hands over are left as they were. At 0 dB
// (or less) nothing is shaped at all, so 0 is a true bypass for comparing
// gains on the phone (Mira, YGBxrJ YqRDoo).
export function louden(samples, gainDb = SPEECH_GAIN_DB) {
  if (!(gainDb > 0)) return Float32Array.from(samples);
  const gain = 10 ** (gainDb / 20);
  const out = new Float32Array(samples.length);
  for (let i = 0; i < samples.length; i += 1) out[i] = shapeSample(samples[i], gain);
  return out;
}
