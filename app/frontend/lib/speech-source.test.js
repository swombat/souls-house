import { expect, test, vi } from 'vitest';
import { SpeechError, createSpeechSource, fetchSpeechText } from './speech-source';

// The server's answer and the synthesis are fakes; blob URLs are numbered so
// the test can see which were made and which were let go.
function harness({ mode = 'voice_mode', answer } = {}) {
  let made = 0;
  const revoked = [];
  const fetchText = vi.fn(async (id) =>
    answer ? answer(id) : { available: true, engine: 'phonon', text: `Text of ${id}.`, voice: 'v1' }
  );
  const synthesize = vi.fn(async () => ({ blob: new Blob(['wav']), duration: 1 }));
  const source = createSpeechSource({
    mode,
    fetchText,
    synthesize,
    streamUrl: (id) => `/messages/${id}/speech`,
    createUrl: () => `blob:${(made += 1)}`,
    revokeUrl: (url) => revoked.push(url),
  });
  return { source, fetchText, synthesize, revoked };
}

test('a Phonon answer is spoken here with its text, voice and signal, and kept: a replay makes nothing again', async () => {
  const { source, fetchText, synthesize } = harness();
  const signal = new AbortController().signal;
  expect(await source.resolve('m1', { signal })).toEqual({ url: 'blob:1', engine: 'phonon' });
  expect(fetchText).toHaveBeenCalledWith('m1', { mode: 'voice_mode', signal });
  expect(synthesize).toHaveBeenCalledWith('Text of m1.', { voice: 'v1', signal });

  expect(await source.resolve('m1')).toEqual({ url: 'blob:1', engine: 'phonon' });
  expect(fetchText).toHaveBeenCalledTimes(1);
  expect(synthesize).toHaveBeenCalledTimes(1);
  expect(source.has('m1')).toBe(true);
});

test('an ElevenLabs answer in voice mode is the streamed speech URL, and nothing is synthesised', async () => {
  const { source, synthesize } = harness({ answer: () => ({ available: true, engine: 'elevenlabs' }) });
  expect(await source.resolve('m2')).toEqual({ url: '/messages/m2/speech', engine: 'elevenlabs' });
  expect(synthesize).not.toHaveBeenCalled();
});

test('an ElevenLabs answer for Listen leaves the URL to that surface', async () => {
  const { source, synthesize } = harness({ mode: 'listen', answer: () => ({ available: true, engine: 'elevenlabs' }) });
  expect(await source.resolve('m3')).toEqual({ url: null, engine: 'elevenlabs' });
  expect(synthesize).not.toHaveBeenCalled();
});

test("an unavailable answer fails with the server's reason and never falls back to the other engine", async () => {
  const { source, synthesize } = harness({
    answer: () => ({ available: false, reason: 'no_key', message: 'Add an ElevenLabs key to hear this resident.' }),
  });
  const failure = await source.resolve('m4').catch((e) => e);
  expect(failure).toBeInstanceOf(SpeechError);
  expect(failure.message).toBe('Add an ElevenLabs key to hear this resident.');
  expect(failure.reason).toBe('no_key');
  expect(synthesize).not.toHaveBeenCalled();
});

test('closing lets go of every URL it made, and nothing resolves afterwards', async () => {
  const { source, revoked, fetchText } = harness();
  await source.resolve('a');
  await source.resolve('b');
  source.close();
  expect(revoked.sort()).toEqual(['blob:1', 'blob:2']);
  const failure = await source.resolve('a').catch((e) => e);
  expect(failure).toBeInstanceOf(SpeechError);
  expect(fetchText).toHaveBeenCalledTimes(2);
});

test('a synthesis that finishes after close is not kept: its URL is never made', async () => {
  let finish;
  const { source, synthesize, revoked } = harness();
  synthesize.mockImplementation(() => new Promise((resolve) => (finish = resolve)));
  const pending = source.resolve('late');
  await vi.waitFor(() => expect(finish).toBeTypeOf('function'));
  source.close();
  finish({ blob: new Blob(['wav']) });
  expect(await pending.catch((e) => e)).toBeInstanceOf(SpeechError);
  expect(source.has('late')).toBe(false);
  expect(revoked).toEqual([]);
});

test('at most 24 replies are kept; the oldest is let go first', async () => {
  const { source, revoked } = harness();
  for (let i = 1; i <= 25; i += 1) await source.resolve(`m${i}`);
  expect(revoked).toEqual(['blob:1']);
  expect(source.has('m1')).toBe(false);
  expect(source.has('m2')).toBe(true);
  expect(source.has('m25')).toBe(true);
});

test('the speech text is asked for by message and surface, and a refusal is a SpeechError', async () => {
  const request = vi.fn(async () => ({ ok: true, json: async () => ({ available: true }) }));
  const signal = new AbortController().signal;
  expect(await fetchSpeechText('m9', { mode: 'listen', signal, request })).toEqual({ available: true });
  const [url, options] = request.mock.calls[0];
  expect(url).toBe('/messages/m9/speech_text?for=listen');
  expect(options).toMatchObject({ signal, credentials: 'same-origin', headers: { Accept: 'application/json' } });

  request.mockImplementation(async () => ({ ok: false, status: 403 }));
  const failure = await fetchSpeechText('m9', { request }).catch((e) => e);
  expect(failure).toBeInstanceOf(SpeechError);
  expect(failure.message).toMatch(/403/);
});

// Found by Tom (Sonnet helper) while writing these tests: a reply made twice
// used to leak the first blob URL.
test('two overlapping resolves of one reply keep the first URL and leave none unrevoked after close', async () => {
  let n = 0;
  const made = [];
  const revoked = [];
  const source = createSpeechSource({
    fetchText: async () => ({ available: true, engine: 'phonon', text: 't' }),
    synthesize: async () => ({ blob: new Blob(['x']) }),
    createUrl: () => {
      const url = `blob:${++n}`;
      made.push(url);
      return url;
    },
    revokeUrl: (url) => revoked.push(url),
  });
  const [first, second] = await Promise.all([source.resolve('a'), source.resolve('a')]);
  expect(second.url).toBe(first.url);
  source.close();
  expect(revoked.sort()).toEqual(made.sort());
});
