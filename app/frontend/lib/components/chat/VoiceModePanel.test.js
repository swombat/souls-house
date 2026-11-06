import { tick } from 'svelte';
import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';

// The microphone is replaced by a fake whose callbacks the test drives, and
// the realtime transcriber by one whose transcripts the test settles. A "turn"
// is the detector saying an utterance began, streamed, and ended.

// The ElevenLabs answer from the speech source (SpeechEngine), given at once:
// a thenable that runs its callback synchronously, so the order of what is
// heard can be asserted step by step as before the source existed. Phonon's
// own path is covered in speech-source.test.js and voice-mode-phonon.test.js.
const syncThen = (value) => ({ then: (ok) => syncThen(ok ? ok(value) : value) });
vi.mock('$lib/speech-source', async () => ({
  accountSpeechEngine: (await import('svelte/store')).writable('elevenlabs'),
  createSpeechSource: () => ({
    resolve: (id) => syncThen({ url: `/messages/${id}/speech`, engine: 'elevenlabs' }),
    close: () => {},
  }),
}));

let callbacks;
let stopped;
let handles;
vi.mock('$lib/voice-mode-capture', () => ({
  captureSupported: () => true,
  startCapture: vi.fn(async (options) => {
    callbacks = options;
    let muted = false;
    const handle = {
      get muted() {
        return muted;
      },
      mute: (on) => (muted = on),
      // A test sets handle.open to a duration to have flush() close that turn,
      // as the real detector does.
      open: null,
      flush: vi.fn(() => {
        if (handle.open === null) return;
        const ms = handle.open;
        handle.open = null;
        options.onturn(ms);
      }),
      alive: true,
      running: true,
      resume: vi.fn(async () => {}),
      stop: vi.fn(async () => (stopped = true)),
    };
    handles?.push(handle);
    return handle;
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
        transcriber.lastCommit = next instanceof Error ? Promise.reject(next) : Promise.resolve(next);
        transcriber.lastCommit.catch(() => {});
        return transcriber.lastCommit;
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
      enqueue: vi.fn((id, options) => player.log.push(options?.resume ? ['enqueue', id, 'resume'] : ['enqueue', id])),
      interrupt: vi.fn(() => {
        player.log.push(['interrupt']);
        return player.interrupts?.shift() ?? [];
      }),
      close: vi.fn(() => player.log.push(['close'])),
    };
    return player;
  }),
}));

// The voice-note upload (#756). By default ElevenLabs hears what the live
// transcriber heard and the house keeps the recording as sig-1; a test can
// queue its own results in scribe.results.
let scribe;
vi.mock('$lib/voice-mode-turn-audio', async (importOriginal) => {
  const real = await importOriginal();
  return {
    ...real,
    transcribeTurn: vi.fn((args) => {
      scribe.calls.push({ length: args.samples.length, sampleRate: args.sampleRate });
      if (scribe.results.length) return Promise.resolve(scribe.results.shift());
      // The live commit happens in the same callback, just after this call.
      return Promise.resolve().then(() =>
        transcriber.lastCommit.then(
          (text) => ({ text: typeof text === 'string' ? text : '', signedId: 'sig-1', error: null }),
          () => ({ text: '', signedId: null, error: 'upload failed' })
        )
      );
    }),
  };
});

import VoiceModePanel from './VoiceModePanel.svelte';

let posts;
beforeEach(() => {
  callbacks = null;
  stopped = false;
  handles = [];
  transcriber = null;
  posts = [];
  scribe = { calls: [], results: [] };
  sessionStorage.clear();
  setVisibility('visible');
  Object.defineProperty(navigator, 'onLine', { configurable: true, get: () => true });
  wakeLocks = [];
  Object.defineProperty(navigator, 'wakeLock', {
    configurable: true,
    value: {
      request: vi.fn(async () => {
        const lock = {
          listeners: [],
          release: vi.fn(async () => {}),
          addEventListener: (type, fn) => lock.listeners.push(fn),
        };
        wakeLocks.push(lock);
        return lock;
      }),
    },
  });
  globalThis.fetch = vi.fn(async (url, options) => {
    const form = options.body;
    posts.push({
      url,
      content: form.get('message[content]'),
      voiceMode: form.get('voice_mode'),
      audio: form.get('audio_signed_id'),
      clientId: form.get('client_message_id'),
    });
    const reply = posts.reply ?? { ok: true, status: 201, body: { id: 'm1' } };
    return { ok: reply.ok, status: reply.status, json: async () => reply.body };
  });
  document.head.innerHTML = '<meta name="csrf-token" content="token">';
});
afterEach(cleanup);

let wakeLocks;
function setVisibility(state) {
  Object.defineProperty(document, 'visibilityState', { configurable: true, get: () => state });
}
function showPage(state) {
  setVisibility(state);
  document.dispatchEvent(new Event('visibilitychange'));
}

const props = { accountId: 'acc', chatId: 'chat', userId: 7 };
function speak(result, ms = 1500) {
  transcriber.results.push(result);
  callbacks.onspeechstart(new Float32Array(7200));
  callbacks.onaudio(new Float32Array(480));
  callbacks.onturn(ms);
}

test('an utterance streams to the transcriber and its text, cleaned of the hand-over phrase, is sent with its recording (#756)', async () => {
  const onsent = vi.fn();
  render(VoiceModePanel, { ...props, onsent });
  await waitFor(() => expect(callbacks).not.toBeNull());
  expect(transcriber.connect).toHaveBeenCalled();
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Waiting for you');

  speak('What is on today? Over to you.');
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(transcriber.log).toEqual([['begin', 7200], ['append', 480], ['commit']]);
  expect(posts[0]).toEqual({
    url: '/accounts/acc/chats/chat/messages',
    content: 'What is on today?',
    voiceMode: '1',
    audio: 'sig-1',
    clientId: expect.stringMatching(/^vm-[a-z0-9]+-[a-z0-9]+$/),
  });
  expect(scribe.calls).toEqual([{ length: 7680, sampleRate: 24000 }]);
  await waitFor(() => expect(screen.getByTestId('voice-mode-heard')).toHaveTextContent('What is on today?'));
  expect(onsent).toHaveBeenCalledWith({ id: 'm1' });
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Waiting for you');
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

test('a turn whose transcripts both fail is held with Retry, and listening goes on (jMapOj)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  speak(new Error('The connection to the transcriber dropped.'));
  await waitFor(() => expect(screen.getByTestId('voice-mode-held-reason')).toHaveTextContent('dropped'));
  expect(screen.getByTestId('voice-mode-held-turn')).toHaveTextContent('not transcribed yet');
  expect(posts).toHaveLength(0);
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Waiting for you');

  // Retry asks ElevenLabs again with the kept recording, then sends.
  scribe.results.push({ text: 'Five, six, seven, eight.', signedId: 'sig-9', error: null });
  await fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toMatchObject({ content: 'Five, six, seven, eight.', audio: 'sig-9' });
  expect(scribe.calls.at(-1).length).toBe(7680);
  await waitFor(() => expect(screen.queryByTestId('voice-mode-held')).toBeNull());
});

test('a failed post keeps the turn; later turns wait behind it and go in order once it is sent (jMapOj)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  posts.reply = { ok: false, status: 500, body: { errors: ['Something broke'] } };
  speak('First thing.');
  await waitFor(() =>
    expect(screen.getByTestId('voice-mode-held-reason')).toHaveTextContent('Not sent: Something broke')
  );
  expect(screen.getByTestId('voice-mode-held-turn')).toHaveTextContent('First thing.');
  expect(JSON.parse(sessionStorage.getItem('voice-mode-held:chat'))).toEqual([
    {
      clientMessageId: posts[0].clientId,
      text: 'First thing.',
      signedId: 'sig-1',
      durationMs: 1500,
      error: 'Something broke',
    },
  ]);

  // The next turn tries the line again; the front fails again, so it waits.
  speak('Second thing.');
  await waitFor(() => expect(screen.getAllByTestId('voice-mode-held-turn')).toHaveLength(2));
  await waitFor(() => expect(screen.getAllByTestId('voice-mode-held-reason')[1]).toHaveTextContent('waiting behind'));
  expect(posts.map((p) => p.content)).toEqual(['First thing.', 'First thing.']);

  posts.reply = null;
  await fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await waitFor(() => expect(screen.queryByTestId('voice-mode-held')).toBeNull());
  expect(posts.map((p) => p.content).slice(-2)).toEqual(['First thing.', 'Second thing.']);
  expect(sessionStorage.getItem('voice-mode-held:chat')).toBeNull();
});

test('Discard drops a held turn and the one behind it goes', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  posts.reply = { ok: false, status: null, body: {} };
  globalThis.fetch.mockImplementationOnce(async () => {
    throw new TypeError('Failed to fetch');
  });
  speak('Drop me.');
  await waitFor(() => expect(screen.getByTestId('voice-mode-held-reason')).toHaveTextContent('could not be reached'));
  posts.reply = null;
  await fireEvent.click(screen.getByRole('button', { name: 'Discard' }));
  await waitFor(() => expect(screen.queryByTestId('voice-mode-held')).toBeNull());
  expect(posts.map((p) => p.content)).toEqual([]);
});

test('a held turn retries itself once when the network comes back, and once after a reload of the tab', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  posts.reply = { ok: false, status: 502, body: {} };
  speak('While offline.');
  await waitFor(() => expect(screen.getByTestId('voice-mode-held')).toBeTruthy());
  posts.reply = null;
  window.dispatchEvent(new Event('online'));
  await waitFor(() => expect(screen.queryByTestId('voice-mode-held')).toBeNull());
  expect(posts.map((p) => p.content)).toEqual(['While offline.', 'While offline.']);

  cleanup();
  sessionStorage.setItem(
    'voice-mode-held:chat',
    JSON.stringify([{ text: 'From before the reload.', signedId: 'sig-r' }])
  );
  render(VoiceModePanel, props);
  await waitFor(() => expect(posts.at(-1)).toMatchObject({ content: 'From before the reload.', audio: 'sig-r' }));
  await waitFor(() => expect(screen.queryByTestId('voice-mode-held')).toBeNull());
});

test('the system muting the mic closes the open turn, says paused, and unmuting picks up again (jMapOj)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  transcriber.results.push('Said before the lock');
  callbacks.onspeechstart(new Float32Array(10));
  handles[0].open = 1200;
  callbacks.oninterrupt('muted');
  expect(handles[0].flush).toHaveBeenCalled();
  await waitFor(() => expect(posts.map((p) => p.content)).toEqual(['Said before the lock']));
  await waitFor(() =>
    expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Paused: the system took the microphone')
  );

  callbacks.onrestore();
  await waitFor(() => expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Waiting for you'));
  expect(handles[0].resume).toHaveBeenCalled();
  expect(transcriber.connect.mock.calls.length).toBeGreaterThan(1);
});

test('the screen going off (pagehide) pauses; coming back reopens a mic whose track ended, with no tap (jMapOj)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  expect(navigator.wakeLock.request).toHaveBeenCalledWith('screen');
  // The browser lets go of the lock when the page is hidden.
  setVisibility('hidden');
  wakeLocks.forEach((lock) => lock.listeners.forEach((fn) => fn()));
  window.dispatchEvent(new Event('pagehide'));
  await waitFor(() => expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Paused: the screen went off'));
  expect(screen.queryByTestId('voice-mode-stale')).toBeNull();

  handles[0].alive = false;
  showPage('visible');
  await waitFor(() => expect(handles).toHaveLength(2));
  expect(handles[0].stop).toHaveBeenCalled();
  await waitFor(() => expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Waiting for you'));
  expect(navigator.wakeLock.request).toHaveBeenCalledTimes(2);

  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(wakeLocks.at(-1).release).toHaveBeenCalled());
});

test('when nothing is being heard the label invites the next thing, not "Listening" (Daniel, jNwAdJ eBVREL)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent(
    'Waiting for you. Speak again to say something else.'
  );
  expect(screen.getByTestId('voice-mode-status')).not.toHaveTextContent('Listening');
  callbacks.onspeechstart(new Float32Array(10));
  await waitFor(() => expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Hearing you'));
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
  expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Waiting for you');
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
  let url;
  player.options.urlFor('r1').then((value) => (url = value));
  expect(url).toBe('/messages/r1/speech');

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

test('older history loaded while in voice mode is not read, and nothing is read while the person speaks', async () => {
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

  player.interrupts = [[{ id: 'first', at: 2, playing: true }]];
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

test('a sent turn loses nothing: what landed while the person spoke is read, then the answer (#758)', async () => {
  const { rerender } = render(VoiceModePanel, { ...props, messages: [] });
  await waitFor(() => expect(callbacks).toBeTruthy());
  transcriber.results.push('Next question.');
  callbacks.onspeechstart(new Float32Array(10));
  const during = reply('during');
  await rerender({ ...props, messages: [during] });
  callbacks.onturn(1500);
  await waitFor(() => expect(player.log.filter(([kind]) => kind === 'enqueue')).toEqual([['enqueue', 'during']]));
  await rerender({ ...props, messages: [during, reply('answer')] });
  expect(player.log.filter(([kind]) => kind === 'enqueue')).toEqual([
    ['enqueue', 'during'],
    ['enqueue', 'answer'],
  ]);
});

test('a reply spoken over comes back after the sent turn: from the top under 5 s, played on from where it paused after (#758)', async () => {
  const { rerender } = render(VoiceModePanel, { ...props, messages: [] });
  await waitFor(() => expect(callbacks).toBeTruthy());
  const long = reply('long');
  const short = reply('short');
  await rerender({ ...props, messages: [long, short] });

  transcriber.results.push('Wait.');
  player.interrupts = [
    [
      { id: 'long', at: 12.4, playing: true },
      { id: 'short', at: 0, playing: false },
    ],
  ];
  callbacks.onspeechstart(new Float32Array(10));
  callbacks.onturn(1500);
  await waitFor(() =>
    expect(player.log.slice(-2)).toEqual([
      ['enqueue', 'long', 'resume'],
      ['enqueue', 'short'],
    ])
  );

  transcriber.results.push('Again.');
  player.interrupts = [[{ id: 'short', at: 3.9, playing: true }]];
  callbacks.onspeechstart(new Float32Array(10));
  callbacks.onturn(1500);
  await waitFor(() => expect(player.log.at(-1)).toEqual(['enqueue', 'short']));
});

test('the message carries the ElevenLabs text; the live text shows grey and pulsing until it lands (#756)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  const clean = deferred();
  scribe.results.push(clean.promise);
  speak('Hey Seuros, what is the time?');
  await waitFor(() =>
    expect(screen.getByTestId('voice-mode-provisional')).toHaveTextContent(
      'Hey Seuros, what is the time? (in progress)'
    )
  );
  expect(screen.getByTestId('voice-mode-provisional').className).toContain('animate-pulse');
  expect(posts).toHaveLength(0);
  clean.resolve({ text: 'Hey, so what is the time?', signedId: 'sig-9', error: null });
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toMatchObject({ content: 'Hey, so what is the time?', audio: 'sig-9' });
  expect(screen.queryByTestId('voice-mode-provisional')).toBeNull();
});

test('when ElevenLabs fails the live text is sent marked rough, with the recording if the house kept it (#756)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  scribe.results.push({ text: '', signedId: 'sig-2', error: 'Transcription failed' });
  speak('Walking the dog now.');
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toMatchObject({ content: '(rough live transcript) Walking the dog now.', audio: 'sig-2' });
});

test('ElevenLabs hearing words the live transcriber missed still sends them (#756)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  scribe.results.push({ text: 'Quietly said.', signedId: 'sig-3', error: null });
  speak('');
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toMatchObject({ content: 'Quietly said.', audio: 'sig-3' });
});

test('a burst that was not speech uploads nothing (#756)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  callbacks.onspeechstart(new Float32Array(10));
  callbacks.onaudio(new Float32Array(10));
  callbacks.ondiscard(120);
  expect(scribe.calls).toEqual([]);
});

test('ready ElevenLabs text is sent without waiting for the live caption (#761)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  const live = deferred();
  scribe.results.push({ text: 'Clean and ready.', signedId: 'sig-5', error: null });
  speak(live.promise);
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toMatchObject({ content: 'Clean and ready.', audio: 'sig-5' });
  live.resolve('Clean and ready');
  await Promise.resolve();
  expect(posts).toHaveLength(1);
  expect(screen.queryByTestId('voice-mode-provisional')).toBeNull();
});

test('End sends a turn whose ElevenLabs text is ready while the live caption is still pending (#761)', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend });
  await waitFor(() => expect(callbacks).not.toBeNull());
  const live = deferred();
  scribe.results.push({ text: 'Said just before End.', signedId: 'sig-6', error: null });
  callbacks.onspeechstart(new Float32Array(10));
  transcriber.results.push(live.promise);
  const { startCapture } = await import('$lib/voice-mode-capture');
  const handle = await startCapture.mock.results.at(-1).value;
  handle.stop.mockImplementation(async () => {
    stopped = true;
    callbacks.onturn(800);
  });
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalledWith({ sent: 1 }));
  expect(posts.map((p) => p.content)).toEqual(['Said just before End.']);
});

test('a stalled upload does not hold later turns: it falls back to rough, and its late result sends nothing (#761)', async () => {
  vi.useFakeTimers({ shouldAdvanceTime: true });
  try {
    render(VoiceModePanel, props);
    await waitFor(() => expect(callbacks).not.toBeNull());
    const stalled = deferred();
    scribe.results.push(stalled.promise);
    scribe.results.push({ text: 'Second turn.', signedId: 'sig-8', error: null });
    speak('First turn');
    speak('Second turn');
    await vi.advanceTimersByTimeAsync(1000);
    expect(posts).toHaveLength(0);
    await vi.advanceTimersByTimeAsync(40_000);
    await waitFor(() => expect(posts).toHaveLength(2));
    expect(posts.map((p) => p.content)).toEqual(['(rough live transcript) First turn', 'Second turn.']);
    stalled.resolve({ text: 'First turn, late.', signedId: 'sig-7', error: null });
    await vi.advanceTimersByTimeAsync(1000);
    expect(posts).toHaveLength(2);
  } finally {
    vi.useRealTimers();
  }
});

test('changing the voice engine while open stops the old reader and reads on with a new one; the same engine changes nothing', async () => {
  const { createPlayer } = await import('$lib/voice-mode-playback');
  const { accountSpeechEngine } = await import('$lib/speech-source');
  accountSpeechEngine.set('elevenlabs');
  createPlayer.mockClear();
  render(VoiceModePanel, { ...props });
  await waitFor(() => expect(callbacks).toBeTruthy());
  const first = player;
  expect(createPlayer).toHaveBeenCalledTimes(1);

  accountSpeechEngine.set('elevenlabs');
  await tick();
  expect(first.log).not.toContainEqual(['close']);
  expect(createPlayer).toHaveBeenCalledTimes(1);

  accountSpeechEngine.set('phonon');
  await tick();
  expect(first.log).toContainEqual(['close']);
  expect(createPlayer).toHaveBeenCalledTimes(2);
  expect(player).not.toBe(first);
  expect(player.log).not.toContainEqual(['close']);
  accountSpeechEngine.set('elevenlabs');
});

test('Retry keeps a turn whose recording is kept again but not transcribed (#797 review)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  speak(new Error('socket closed'));
  await waitFor(() => expect(screen.getByTestId('voice-mode-held')).toBeTruthy());
  scribe.results.push({ text: '', signedId: 'sig-kept', error: 'Transcription failed.' });
  await fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await waitFor(() =>
    expect(screen.getByTestId('voice-mode-held-reason')).toHaveTextContent('Not sent: Transcription failed.')
  );
  expect(posts).toHaveLength(0);
});

test('End does not lose a closed turn whose clean transcript is still on its way (#797 review)', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend, endDrainMs: 20 });
  await waitFor(() => expect(callbacks).not.toBeNull());
  const slow = deferred();
  scribe.results.push(slow.promise);
  speak('Live words');
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalled());
  expect(posts).toHaveLength(0);
  slow.resolve({ text: 'Clean words, late.', signedId: 'sig-late', error: null });
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0]).toMatchObject({ content: 'Clean words, late.', audio: 'sig-late' });
});

test('after End, a late turn that cannot be sent is kept for next time as its caption', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend, endDrainMs: 20 });
  await waitFor(() => expect(callbacks).not.toBeNull());
  const slow = deferred();
  scribe.results.push(slow.promise);
  callbacks.onspeechstart(new Float32Array(10));
  transcriber.options.onDelta('five, six, seven, eight');
  await waitFor(() => expect(screen.getByTestId('voice-mode-caption')).toBeTruthy());
  transcriber.results.push(new Error('socket closed'));
  callbacks.onturn(1500);
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalled());
  slow.resolve({ text: '', signedId: null, error: 'Failed to fetch' });
  // Caption fallback: sent as rough rather than held, since the words exist.
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0].content).toContain('five, six, seven, eight');
});

test('End with a clean transcript still pending writes the turn down first; a reopened panel sends it, and the late result does not send it again (#797 review)', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend, endDrainMs: 20 });
  await waitFor(() => expect(callbacks).not.toBeNull());
  const slow = deferred();
  scribe.results.push(slow.promise);
  callbacks.onspeechstart(new Float32Array(10));
  transcriber.options.onDelta('five, six, seven, eight');
  await waitFor(() => expect(screen.getByTestId('voice-mode-caption')).toBeTruthy());
  transcriber.results.push(new Promise(() => {}));
  callbacks.onturn(1500);
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalled());
  const stored = JSON.parse(sessionStorage.getItem('voice-mode-held:chat'));
  expect(stored).toHaveLength(1);
  expect(stored[0].text).toContain('five, six, seven, eight');
  const identity = stored[0].clientMessageId;
  expect(identity).toMatch(/^[A-Za-z0-9_-]{8,64}$/);

  cleanup();
  render(VoiceModePanel, props);
  await waitFor(() => expect(posts).toHaveLength(1));
  expect(posts[0].clientId).toBe(identity);

  slow.resolve({ text: 'Five, six, seven, eight.', signedId: 'sig-late', error: null });
  await waitFor(() => expect(sessionStorage.getItem('voice-mode-held:chat')).toBeNull());
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(posts).toHaveLength(1);
});

test('End writes down the live text that arrived after the turn closed, not only the caption before it (#797 review)', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend, endDrainMs: 20 });
  await waitFor(() => expect(callbacks).not.toBeNull());
  const slow = deferred();
  scribe.results.push(slow.promise);
  speak('Words received after commit.');
  await waitFor(() => expect(screen.getByText(/Words received after commit/)).toBeTruthy());
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalled());
  const stored = JSON.parse(sessionStorage.getItem('voice-mode-held:chat'));
  expect(stored).toHaveLength(1);
  expect(stored[0].text).toContain('Words received after commit');
});

test('Discard in a reopened panel is final: the panel that ended does not send the turn when its late result arrives (#797 review)', async () => {
  const onend = vi.fn();
  render(VoiceModePanel, { ...props, onend, endDrainMs: 20 });
  await waitFor(() => expect(callbacks).not.toBeNull());
  const slow = deferred();
  scribe.results.push(slow.promise);
  speak('Do not send this.');
  await fireEvent.click(screen.getByRole('button', { name: 'End voice mode' }));
  await waitFor(() => expect(onend).toHaveBeenCalled());
  expect(JSON.parse(sessionStorage.getItem('voice-mode-held:chat'))).toHaveLength(1);

  cleanup();
  posts.reply = { ok: false, status: 502, body: {} };
  render(VoiceModePanel, props);
  await waitFor(() => expect(posts).toHaveLength(1));
  await waitFor(() => expect(screen.getByRole('button', { name: 'Discard' })).toBeTruthy());
  posts.reply = null;
  await fireEvent.click(screen.getByRole('button', { name: 'Discard' }));
  expect(sessionStorage.getItem('voice-mode-held:chat')).toBeNull();

  slow.resolve({ text: 'Do not send this.', signedId: 'sig-late', error: null });
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(posts).toHaveLength(1);
  expect(sessionStorage.getItem('voice-mode-held:chat')).toBeNull();
});

test('a retried held turn is posted with the identity of its first send (#797 review)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  posts.reply = { ok: false, status: 502, body: {} };
  speak('Once only.');
  await waitFor(() => expect(screen.getByTestId('voice-mode-held')).toBeTruthy());
  posts.reply = null;
  await fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await waitFor(() => expect(posts).toHaveLength(2));
  expect(posts[0].clientId).toBeTruthy();
  expect(posts[1].clientId).toBe(posts[0].clientId);
});

function fakeMediaDevices() {
  const listeners = [];
  const devices = {
    addEventListener: (type, fn) => type === 'devicechange' && listeners.push(fn),
    removeEventListener: (type, fn) => listeners.splice(listeners.indexOf(fn), 1),
    change: () => listeners.forEach((fn) => fn()),
    listeners,
  };
  Object.defineProperty(navigator, 'mediaDevices', { configurable: true, value: devices });
  return devices;
}

test('headphones joining between turns reopen the microphone so the phone picks their route (jBVWGj)', async () => {
  const devices = fakeMediaDevices();
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  devices.change();
  devices.change();
  await waitFor(() => expect(handles).toHaveLength(2), { timeout: 2000 });
  expect(handles[0].stop).toHaveBeenCalled();
  await waitFor(() => expect(screen.getByTestId('voice-mode-status')).toHaveTextContent('Waiting for you'));
});

test('headphones joining mid-turn wait for the turn to close before the microphone reopens (jBVWGj)', async () => {
  const devices = fakeMediaDevices();
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  transcriber.results.push('Still talking');
  callbacks.onspeechstart(new Float32Array(10));
  devices.change();
  await new Promise((resolve) => setTimeout(resolve, 1000));
  expect(handles).toHaveLength(1);
  callbacks.onturn(1500);
  await waitFor(() => expect(handles).toHaveLength(2));
  await waitFor(() => expect(posts.map((p) => p.content)).toEqual(['Still talking']));
});

test('the next transcription session carries a trace of what the phone did to the microphone (jBVWGj)', async () => {
  render(VoiceModePanel, props);
  await waitFor(() => expect(callbacks).not.toBeNull());
  showPage('hidden');
  callbacks.onspeechstart(new Float32Array(10));
  handles[0].open = 4400;
  transcriber.results.push('Cut off');
  callbacks.oninterrupt('muted');
  const urls = [];
  globalThis.fetch = vi.fn(async (url) => {
    urls.push(url);
    return { ok: true, status: 200, json: async () => ({ token: 't' }) };
  });
  await transcriber.options.fetchSession();
  const trace = decodeURIComponent(urls[0].split('?trace=')[1] || '');
  expect(trace).toMatch(/^hidden@0\.0,int:muted@[\d.]+,pause:muted@[\d.]+,turn:4\.4s@[\d.]+$/);
  // Taken once: the next request carries nothing new.
  await transcriber.options.fetchSession();
  expect(urls[1]).toBe('/accounts/acc/chats/chat/voice_mode_session');
});
