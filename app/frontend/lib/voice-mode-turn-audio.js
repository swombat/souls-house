import { readTranscription, transcriptionRequest } from '$lib/voice-note-recovery';

// Each spoken turn in voice mode is also kept as a recording and transcribed
// the way a voice note is (#756, Daniel in eqRORj jKVlPJ/eBzxKe): the live
// OpenAI transcriber only cuts turns and shows a provisional caption; the
// message carries ElevenLabs' text (scribe_v2 with the account's glossary as
// keyterms, Chats::TranscriptionsController) and the recording as its
// attachment, as any voice note does.

// The samples of the turn being spoken, from its pre-roll to its end.
export function createTurnRecorder({ sampleRate }) {
  let chunks = null;
  return {
    sampleRate,
    begin(samples) {
      chunks = samples?.length ? [samples] : [];
    },
    append(samples) {
      if (chunks && samples?.length) chunks.push(samples);
    },
    discard() {
      chunks = null;
    },
    // The finished turn as one Float32Array, or null if none was open.
    take() {
      if (!chunks) return null;
      const out = new Float32Array(chunks.reduce((n, c) => n + c.length, 0));
      let at = 0;
      for (const c of chunks) {
        out.set(c, at);
        at += c.length;
      }
      chunks = null;
      return out;
    },
  };
}

// 16-bit mono PCM WAV.
export function encodeWav(samples, sampleRate) {
  return new Blob([wavBytes(samples, sampleRate)], { type: 'audio/wav' });
}

export function wavBytes(samples, sampleRate) {
  const bytes = new ArrayBuffer(44 + samples.length * 2);
  const view = new DataView(bytes);
  const text = (offset, value) => [...value].forEach((c, i) => view.setUint8(offset + i, c.charCodeAt(0)));
  text(0, 'RIFF');
  view.setUint32(4, 36 + samples.length * 2, true);
  text(8, 'WAVEfmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  text(36, 'data');
  view.setUint32(40, samples.length * 2, true);
  for (let i = 0; i < samples.length; i += 1) {
    const s = Math.max(-1, Math.min(1, samples[i]));
    view.setInt16(44 + i * 2, s < 0 ? s * 0x8000 : s * 0x7fff, true);
  }
  return bytes;
}

// Uploads one turn's recording and resolves to
// { text, signedId, error }: text is ElevenLabs' transcript ('' when it heard
// no words or failed), signedId the stored recording when the house kept it.
export async function transcribeTurn({ accountId, chatId, samples, sampleRate, request = transcriptionRequest }) {
  const form = new FormData();
  form.append('audio', encodeWav(samples, sampleRate), 'voice-mode-turn.wav');
  const result = await readTranscription(await request({ accountId, chatId }, 'POST', form));
  if (result.ok) return { text: result.text, signedId: result.signedId, error: null };
  return { text: '', signedId: result.saved === 'saved' ? result.signedId || null : null, error: result.error };
}

// What a turn is sent as. ElevenLabs' text when it has words; otherwise the
// live caption, marked as rough so neither the person nor the resident takes
// it for a clean transcript; nothing when neither heard words.
export const ROUGH_MARK = '(rough live transcript)';

export function turnContent({ clean, live }) {
  if (clean?.trim()) return { text: clean.trim(), rough: false };
  if (live?.trim()) return { text: `${ROUGH_MARK} ${live.trim()}`, rough: true };
  return { text: '', rough: false };
}
