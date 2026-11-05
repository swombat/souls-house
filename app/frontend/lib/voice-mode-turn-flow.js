// What a finished voice-mode turn sends. The recording's ElevenLabs text
// decides the turn; it is not held for the live caption: a clean result sends
// at once, while the caption is still only provisional (Mira, #761 review).
// Only when the clean text is missing does the turn wait for the live caption,
// to send it marked as rough (#756).
import { stripReleasePhrase } from '$lib/voice-mode';
import { transcribeTurn, turnContent } from '$lib/voice-mode-turn-audio';

// Above transcribeTurn's own 30 s bound; only reached by an unbounded promise.
export const CLEAN_BACKSTOP_MS = 35_000;

const NO_RECORDING = { text: '', signedId: null, error: null };

// Starts the clean transcription of a turn's recording. Never rejects: a
// failure is a result with an error, so the turn can fall back to the caption.
export function startCleanTurn({ accountId, chatId, samples, sampleRate }) {
  if (!samples?.length) return Promise.resolve(NO_RECORDING);
  return transcribeTurn({ accountId, chatId, samples, sampleRate }).catch((error) => ({
    text: '',
    signedId: null,
    error: error?.message,
  }));
}

export function settleWithin(promise, ms, fallback) {
  let timer;
  return Promise.race([
    Promise.resolve(promise).catch(() => fallback),
    new Promise((resolve) => (timer = setTimeout(() => resolve(fallback), ms))),
  ]).finally(() => clearTimeout(timer));
}

// Resolves to { text, signedId, note, failed }: text to send (empty when there
// were no words, with note saying why), and the recording's signed id when it
// has one. failed is true when the turn has no text because something broke
// (the upload and the live transcript both failed), not because it was silent:
// such a turn is kept for a retry, never dropped (jMapOj).
// caption is the live text the page showed while the turn was spoken. When the
// transcriber's own final answer is lost (the socket dropped with the screen
// off), that caption is still what the person said, and is sent as rough
// rather than thrown away (Daniel's "five, six, seven, eight", jNwAdJ YVvdnw).
// onProvisional fires with the live caption's text while the clean text is
// still pending, so the panel can show it as in progress. transcribeTurn
// bounds the clean request itself; the backstop keeps the queue moving if a
// caller hands in an unbounded promise.
export async function resolveTurn({
  transcript,
  clean,
  durationMs,
  caption = '',
  onProvisional,
  backstopMs = CLEAN_BACKSTOP_MS,
}) {
  let current = true;
  const live = Promise.resolve(transcript).then(
    (value) => ({ text: stripReleasePhrase(value).text, error: null }),
    (error) => ({ text: '', error })
  );
  live.then(({ text }) => {
    if (current) onProvisional?.(text || stripReleasePhrase(caption).text);
  });
  const recording = await settleWithin(clean, backstopMs, { text: '', signedId: null, error: 'timeout' });
  const cleanText = stripReleasePhrase(recording?.text || '').text;
  let liveText = '';
  let liveError = null;
  if (!cleanText.trim()) ({ text: liveText, error: liveError } = await live);
  if (!cleanText.trim() && !liveText.trim()) liveText = stripReleasePhrase(caption).text;
  current = false;
  const { text } = turnContent({ clean: cleanText, live: liveText });
  const signedId = recording?.signedId || null;
  if (text) return { text, signedId, note: '', failed: false };
  // Silence is a clean answer with no words. A failed upload with no live
  // answer either is a failure: the words may be in the recording.
  const failed = Boolean(recording?.error) && !signedId;
  if (failed) {
    const reason = liveError?.message || recording.error || 'Transcription failed.';
    return { text: '', signedId, note: reason, failed: true };
  }
  const note =
    liveError && !signedId
      ? liveError?.message || 'Transcription failed.'
      : `Heard ${Math.round(durationMs / 1000)}s of sound but no words.`;
  return { text: '', signedId, note, failed: false };
}
