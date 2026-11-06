import { accountChatMessagesPath, accountChatVoiceModeSessionPath } from '@/routes';

// The two house requests voice mode makes (VoiceModePanel).
const csrf = () => document.querySelector('meta[name="csrf-token"]')?.content || '';

// A fresh short-lived transcription secret. Resolves { ok, status, data };
// throws only when the house cannot be reached. `trace` is the panel's line of
// what the phone did to the microphone since the last request
// (voice-mode-trace.js); it rides in the query string so the web log shows it.
export async function requestVoiceSession(accountId, chatId, { trace = '' } = {}) {
  let response;
  const path = accountChatVoiceModeSessionPath(accountId, chatId);
  try {
    response = await fetch(trace ? `${path}?trace=${encodeURIComponent(trace)}` : path, {
      method: 'POST',
      headers: { Accept: 'application/json', 'X-CSRF-Token': csrf() },
      credentials: 'same-origin',
    });
  } catch {
    throw new Error('Could not reach the house to start transcription.');
  }
  const data = await response.json().catch(() => ({}));
  return { ok: response.ok, status: response.status, data };
}

// Posts one spoken turn as a voice_mode message, with its recording when kept. A send that hangs must not
// hold every later turn behind it, so it aborts after timeoutMs. Resolves
// { ok, status, data }; status is null when the request never completed.
export async function postVoiceMessage({
  accountId,
  chatId,
  userId,
  text,
  audioSignedId = null,
  clientMessageId = null,
  timeoutMs,
}) {
  const form = new FormData();
  form.append('message[content]', text);
  form.append('voice_mode', '1');
  // The turn's recording, kept like a voice note's (#756).
  if (audioSignedId) form.append('audio_signed_id', audioSignedId);
  // The turn's identity for its whole life, so a retry is never a second post (#797).
  if (clientMessageId) form.append('client_message_id', clientMessageId);
  const abort = new AbortController();
  const timer = setTimeout(() => abort.abort(), timeoutMs);
  let response = null;
  try {
    response = await fetch(accountChatMessagesPath(accountId, chatId), {
      method: 'POST',
      headers: { Accept: 'application/json', 'X-CSRF-Token': csrf(), 'X-Draft-User': userId },
      credentials: 'same-origin',
      body: form,
      signal: abort.signal,
    });
  } catch {
    response = null;
  } finally {
    clearTimeout(timer);
  }
  const data = response ? await response.json().catch(() => ({})) : {};
  return { ok: Boolean(response?.ok), status: response?.status ?? null, data };
}
