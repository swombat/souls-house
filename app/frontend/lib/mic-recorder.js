// Small pieces of the mic button's recorder lifecycle, kept out of the component.

export function stopStream(stream) {
  stream?.getTracks().forEach((track) => track.stop());
}

export function recorderOptions(Recorder = globalThis.MediaRecorder) {
  const mimeType = ['audio/webm;codecs=opus', 'audio/webm', 'audio/mp4'].find((type) => Recorder.isTypeSupported(type));
  return mimeType ? { mimeType } : {};
}

// Stops a recorder the button has lost track of, without transcribing it, and closes its mic.
export function abandonRecorder(recorder) {
  if (!recorder) return;
  recorder.onstop = () => stopStream(recorder.stream);
  if (recorder.state !== 'inactive') recorder.stop();
  else stopStream(recorder.stream);
}

export function micErrorMessage(err) {
  if (err?.name === 'NotAllowedError') {
    return 'Microphone access denied. Please allow microphone access in your browser settings.';
  }
  if (err?.name === 'NotFoundError') return 'No microphone found. Please connect a microphone and try again.';
  return 'Could not start recording';
}

// A take from the recorder, ready for the Field's recording upload. The server
// accepts a bare audio/<subtype> type, so codec parameters are dropped
// ("audio/webm;codecs=opus" becomes "audio/webm") and the name gets the
// matching extension.
export function voiceNoteFile(chunks, mimeType, title) {
  const type = (mimeType || 'audio/webm').split(';')[0].trim().toLowerCase();
  const extension = type === 'audio/mp4' ? 'm4a' : type === 'audio/ogg' ? 'ogg' : 'webm';
  const name = `${(title || 'Voice note').replace(/[\\/:*?"<>|]+/g, '-').slice(0, 200)}.${extension}`;
  return new File(chunks, name, { type });
}

// "Voice note · 26 Nov, 09:47", in the person's own clock.
export function voiceNoteTitle(at = new Date(), locale = undefined) {
  const day = at.toLocaleDateString(locale || 'en-GB', { day: 'numeric', month: 'short' });
  const time = at.toLocaleTimeString(locale || 'en-GB', { hour: '2-digit', minute: '2-digit', hour12: false });
  return `Voice note · ${day}, ${time}`;
}

export function formatElapsed(ms) {
  const total = Math.max(0, Math.floor(ms / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = String(total % 60).padStart(2, '0');
  return `${minutes}:${seconds}`;
}
