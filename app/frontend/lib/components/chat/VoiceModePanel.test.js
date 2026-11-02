import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';

// The microphone is replaced by a fake whose callbacks the test drives, so a
// "turn" is the detector saying an utterance ended.
let callbacks;
let stopped;
vi.mock('$lib/voice-mode-capture', () => ({
  captureSupported: () => true,
  startCapture: vi.fn(async (options) => {
    callbacks = options;
    let muted = false;
    return {
      get muted() {
        return muted;
      },
      mute: (on) => (muted = on),
      flush: () => {},
      stop: vi.fn(async () => (stopped = true)),
    };
  }),
}));

let transcriptions;
vi.mock('$lib/voice-note-recovery', async (importOriginal) => {
  const actual = await importOriginal();
  return {
    ...actual,
    transcriptionRequest: vi.fn(async (where, method, form) => {
      const next = transcriptions.shift();
      transcriptions.sent ??= [];
      transcriptions.sent.push({ where, method, filename: form.get('audio')?.name });
      return { ok: next.ok, status: next.status ?? 200, text: async () => JSON.stringify(next.body) };
    }),
  };
});

import VoiceModePanel from './VoiceModePanel.svelte';

let posts;
beforeEach(() => {
  callbacks = null;
  stopped = false;
  transcriptions = [];
  posts = [];
  globalThis.fetch = vi.fn(async (url, options) => {
    const form = options.body;
    posts.push({
      url,
      content: form.get('message[content]'),
      voiceMode: form.get('voice_mode'),
      audio: form.get('audio_signed_id'),
    });
    const reply = posts.reply ?? { ok: true, status: 201, body: { id: 'm1' } };
    return { ok: reply.ok, status: reply.status, json: async () => reply.body };
  });
  document.head.innerHTML = '<meta name="csrf-token" content="token">';
});
afterEach(cleanup);

const props = { accountId: 'acc', chatId: 'chat', userId: 7 };
const turn = (ms = 1500) => callbacks.onturn(new Blob(['wav'], { type: 'audio/wav' }), ms);

test('an utterance is transcribed, cleaned of the hand-over phrase and sent as a voice mode message', async () => {
  const onsent = vi.fn();
  render(VoiceModePanel, { ...props, onsent });
  await waitFor(() => expect(callbacks).not.toBeNull());
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Listening');

  transcriptions.push({ ok: true, body: { text: 'What is on today? Over to you.', audio_signed_id: 'blob-1' } });
  turn();
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toEqual({
    url: '/accounts/acc/chats/chat/messages',
    content: 'What is on today?',
    voiceMode: '1',
    audio: 'blob-1',
  });
  expect(transcriptions.sent[0]).toEqual({
    where: { accountId: 'acc', chatId: 'chat' },
    method: 'POST',
    filename: 'turn.wav',
  });
  await waitFor(() => expect(screen.getByTestId('voice-mode-heard')).toHaveTextContent('What is on today?'));
  expect(onsent).toHaveBeenCalledWith({ id: 'm1' });
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Listening');
});

test('sound without words is reported and nothing is sent', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  transcriptions.push({
    ok: false,
    status: 422,
    body: { error: 'No speech detected', retryable: true, saved: true, audio_signed_id: 'b' },
  });
  turn(2100);
  await waitFor(() => expect(screen.getByTestId('voice-mode-note')).toHaveTextContent('No speech detected'));
  expect(posts).toHaveLength(0);
});

test('a refusal because the mode is off ends voice mode and says why', async () => {
  const onend = vi.fn();
  const onerror = vi.fn();
  render(VoiceModePanel, { ...props, onend, onerror });
  await waitFor(() => expect(callbacks).not.toBeNull());
  posts.reply = {
    ok: false,
    status: 403,
    body: { errors: ['Voice mode is not available in this account, so your message was not sent.'] },
  };
  transcriptions.push({ ok: true, body: { text: 'Hello', audio_signed_id: 'blob-2' } });
  turn();
  await waitFor(() => expect(onend).toHaveBeenCalledWith({ sent: 0 }));
  expect(onerror).toHaveBeenCalledWith(expect.stringContaining('not available'));
  expect(stopped).toBe(true);
});

test('mute keeps the microphone open but marks the state; End stops the capture', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend });
  await waitFor(() => expect(callbacks).not.toBeNull());
  await fireEvent.click(screen.getByRole('button', { name: 'Mute' }));
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Muted');
  await fireEvent.click(screen.getByRole('button', { name: 'Unmute' }));
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Listening');
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalledWith({ sent: 0 }));
  expect(stopped).toBe(true);
});
