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
