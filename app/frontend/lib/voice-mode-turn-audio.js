import { encodeWav } from '$lib/voice-mode';
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
