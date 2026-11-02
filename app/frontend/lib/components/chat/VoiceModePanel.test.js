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

let player;
vi.mock('$lib/voice-mode-playback', () => ({
  createPlayer: vi.fn((options) => {
    player = {
      options,
      log: [],
      enqueue: vi.fn((id) => player.log.push(['enqueue', id])),
      interrupt: vi.fn(() => player.log.push(['interrupt'])),
      close: vi.fn(() => player.log.push(['close'])),
    };
    return player;
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

function deferred() {
  let resolve;
  const promise = new Promise((r) => (resolve = r));
  return { promise, resolve };
}

test('Mute works while an earlier turn is still transcribing, and the mic is muted at once', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  const pending = deferred();
  speak(pending.promise);
  await waitFor(() => expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Transcribing'));
  const button = screen.getByRole('button', { name: 'Mute' });
  expect(button).not.toBeDisabled();
  await fireEvent.click(button);
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Muted');
  pending.resolve('Earlier sentence.');
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0].content).toBe('Earlier sentence.');
  await waitFor(() =>
    expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Muted. Nothing you say is sent.')
  );
  expect(screen.getByRole('button', { name: 'Unmute' })).toHaveAttribute('aria-pressed', 'true');
});

test('Mute works while a message is still being sent', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  const reply = deferred();
  const realFetch = globalThis.fetch;
  globalThis.fetch = vi.fn(async (url, options) => {
    await reply.promise;
    return realFetch(url, options);
  });
  speak('Send this.');
  await waitFor(() => expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Sending'));
  const button = screen.getByRole('button', { name: 'Mute' });
  expect(button).not.toBeDisabled();
  await fireEvent.click(button);
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Muted');
  reply.resolve();
  await waitFor(() => expect(posts).toHaveLength(1));
  await waitFor(() =>
    expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Muted. Nothing you say is sent.')
  );
});

let clock = 0;
const reply = (id, extra = {}) => ({
  id,
  role: 'assistant',
  voice_available: true,
  completed: true,
  streaming: false,
  content: 'Spoken back.',
  created_at: new Date(Date.UTC(2026, 10, 2, 9, 0, clock++)).toISOString(),
  ...extra,
});

test('replies that arrive after voice mode opens are read aloud, the backlog is not, and speaking interrupts them', async () => {
  const { rerender } = render(VoiceModePanel, { ...props, messages: [reply('old')] });
  await waitFor(() => expect(callbacks).toBeTruthy());
  expect(player.options.urlFor('r1')).toBe('/messages/r1/speech');

  await rerender({ ...props, messages: [reply('old'), reply('r1', { streaming: true, completed: false })] });
  await rerender({ ...props, messages: [reply('old'), reply('r1'), reply('p1', { progress_message: true })] });
  expect(player.log).toEqual([
    ['enqueue', 'r1'],
    ['enqueue', 'p1'],
  ]);

  player.options.onchange('r1');
  await waitFor(() => expect(screen.getByTestId('voice-mode-status').textContent).toMatch(/Speaking/));
  callbacks.onspeechstart(new Float32Array(10));
  expect(player.log.at(-1)).toEqual(['interrupt']);

  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(player.log.at(-1)).toEqual(['close']));
});

test('older history loaded while in voice mode is not read, and a reply interrupted mid-arrival stays unread', async () => {
  const earlier = reply('earlier');
  const old = reply('old');
  const pending = reply('pending', { streaming: true, completed: false });
  const { rerender } = render(VoiceModePanel, { ...props, messages: [old, pending] });
  await waitFor(() => expect(callbacks).toBeTruthy());

  await rerender({ ...props, messages: [earlier, old, pending] });
  callbacks.onspeechstart(new Float32Array(10));
  await rerender({ ...props, messages: [earlier, old, { ...pending, streaming: false, completed: true }] });
  const during = reply('during', { progress_message: true });
  await rerender({ ...props, messages: [earlier, old, { ...pending, completed: true, streaming: false }, during] });
  expect(player.log.filter(([kind]) => kind === 'enqueue')).toEqual([]);
});

test('a burst that was not speech consumes no reply: the cut-off reply and what landed meanwhile are read (#748)', async () => {
  const { rerender } = render(VoiceModePanel, { ...props, messages: [] });
  await waitFor(() => expect(callbacks).toBeTruthy());
  const first = reply('first', { author_name: 'Lume' });
  await rerender({ ...props, messages: [first] });
  player.options.onchange('first');
  await waitFor(() => expect(screen.getByTestId('voice-mode-reply').textContent).toMatch(/Lume:\s*Spoken back\./));

  callbacks.onspeechstart(new Float32Array(10));
  const during = reply('during');
  await rerender({ ...props, messages: [first, during] });
  expect(player.log.filter(([kind]) => kind === 'enqueue')).toEqual([['enqueue', 'first']]);

  callbacks.ondiscard(120);
  expect(player.log.slice(-2)).toEqual([
    ['enqueue', 'first'],
    ['enqueue', 'during'],
  ]);
});

test('a sent turn supersedes what landed while the person spoke; the next reply is read', async () => {
  const { rerender } = render(VoiceModePanel, { ...props, messages: [] });
  await waitFor(() => expect(callbacks).toBeTruthy());
  transcriber.results.push('Next question.');
  callbacks.onspeechstart(new Float32Array(10));
  const during = reply('during');
  await rerender({ ...props, messages: [during] });
  callbacks.onturn(1500);
  await rerender({ ...props, messages: [during, reply('answer')] });
  expect(player.log.filter(([kind]) => kind === 'enqueue')).toEqual([['enqueue', 'answer']]);
});
