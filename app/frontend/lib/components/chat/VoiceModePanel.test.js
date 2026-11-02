import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';

// The microphone is replaced by a fake whose callbacks the test drives, and
// the realtime transcriber by one whose transcripts the test settles. A "turn"
// is the detector saying an utterance began, streamed, and ended.
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

let transcriber;
vi.mock('$lib/voice-mode-realtime', () => ({
  createTranscriber: vi.fn((options) => {
    transcriber = {
      options,
      log: [],
      results: [],
      connect: vi.fn(async () => {}),
      begin: vi.fn((samples) => transcriber.log.push(['begin', samples.length])),
      append: vi.fn((samples) => transcriber.log.push(['append', samples.length])),
      discard: vi.fn(() => transcriber.log.push(['discard'])),
      commit: vi.fn(() => {
        transcriber.log.push(['commit']);
        const next = transcriber.results.shift();
        return next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
      }),
      close: vi.fn(() => transcriber.log.push(['close'])),
    };
    return transcriber;
  }),
}));

import VoiceModePanel from './VoiceModePanel.svelte';

let posts;
beforeEach(() => {
  callbacks = null;
  stopped = false;
  transcriber = null;
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
function speak(result, ms = 1500) {
  transcriber.results.push(result);
  callbacks.onspeechstart(new Float32Array(7200));
  callbacks.onaudio(new Float32Array(480));
  callbacks.onturn(ms);
}

test('an utterance streams to the transcriber and its text, cleaned of the hand-over phrase, is sent with no recording', async () => {
  const onsent = vi.fn();
  render(VoiceModePanel, { ...props, onsent });
  await waitFor(() => expect(callbacks).not.toBeNull());
  expect(transcriber.connect).toHaveBeenCalled();
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Listening');

  speak('What is on today? Over to you.');
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(transcriber.log).toEqual([['begin', 7200], ['append', 480], ['commit']]);
  expect(posts[0]).toEqual({
    url: '/accounts/acc/chats/chat/messages',
    content: 'What is on today?',
    voiceMode: '1',
    audio: null,
  });
  await waitFor(() => expect(screen.getByTestId('voice-mode-heard')).toHaveTextContent('What is on today?'));
  expect(onsent).toHaveBeenCalledWith({ id: 'm1' });
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Listening');
});

test('the caption shows the words as they arrive and clears when the turn is sent', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  callbacks.onspeechstart(new Float32Array(10));
  transcriber.options.onDelta('What is');
  await waitFor(() => expect(screen.getByTestId('voice-mode-caption')).toHaveTextContent('What is'));
  transcriber.results.push('What is on');
  callbacks.onturn(900);
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(screen.queryByTestId('voice-mode-caption')).toBeNull();
});

test('a burst that was not speech clears the server buffer and sends nothing', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  callbacks.onspeechstart(new Float32Array(10));
  callbacks.ondiscard(120);
  expect(transcriber.log).toEqual([['begin', 10], ['discard']]);
  expect(posts).toHaveLength(0);
});

test('sound without words is reported and nothing is sent', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  speak('', 2100);
  await waitFor(() =>
    expect(screen.getByTestId('voice-mode-note')).toHaveTextContent('Heard 2s of sound but no words')
  );
  expect(posts).toHaveLength(0);
});

test('a transcription failure is reported and listening goes on', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  speak(new Error('The connection to the transcriber dropped.'));
  await waitFor(() => expect(screen.getByTestId('voice-mode-note')).toHaveTextContent('dropped'));
  expect(posts).toHaveLength(0);
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Listening');
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
  speak('Hello');
  await waitFor(() => expect(onend).toHaveBeenCalledWith({ sent: 0 }));
  expect(onerror).toHaveBeenCalledWith(expect.stringContaining('not available'));
  expect(stopped).toBe(true);
  expect(transcriber.close).toHaveBeenCalled();
});

test('the session secret comes from the voice mode session endpoint; a 403 there ends the mode', async () => {
  const onend = vi.fn();
  const onerror = vi.fn();
  render(VoiceModePanel, { ...props, onend, onerror });
  await waitFor(() => expect(callbacks).not.toBeNull());
  globalThis.fetch = vi.fn(async () => ({
    ok: false,
    status: 403,
    json: async () => ({ error: 'Voice mode is not available in this account.' }),
  }));
  await expect(transcriber.options.fetchSession()).rejects.toThrow('not available');
  expect(globalThis.fetch).toHaveBeenCalledWith(
    '/accounts/acc/chats/chat/voice_mode_session',
    expect.objectContaining({ method: 'POST' })
  );
  await waitFor(() => expect(onend).toHaveBeenCalledWith({ sent: 0 }));
  expect(onerror).toHaveBeenCalledWith('Voice mode is not available in this account.');
});

test('End sends the sentence in progress before closing', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend });
  await waitFor(() => expect(callbacks).not.toBeNull());
  callbacks.onspeechstart(new Float32Array(10));
  transcriber.results.push('Last words');
  // The real capture closes the open turn when it stops.
  const { startCapture } = await import('$lib/voice-mode-capture');
  const handle = await startCapture.mock.results.at(-1).value;
  handle.stop.mockImplementation(async () => {
    stopped = true;
    callbacks.onturn(800);
  });
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalledWith({ sent: 1 }));
  expect(posts.map((p) => p.content)).toEqual(['Last words']);
  expect(transcriber.close).toHaveBeenCalled();
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
