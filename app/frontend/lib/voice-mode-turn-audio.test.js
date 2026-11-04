import { expect, test, vi } from 'vitest';
import { createTurnRecorder, transcribeTurn, turnContent } from './voice-mode-turn-audio';

test('the recorder keeps one turn from its pre-roll to its end, and nothing after a discard', () => {
  const recorder = createTurnRecorder({ sampleRate: 24000 });
  expect(recorder.take()).toBeNull();
  recorder.append(new Float32Array([9]));
  expect(recorder.take()).toBeNull();
  recorder.begin(new Float32Array([0.1, 0.2]));
  recorder.append(new Float32Array([0.3]));
  expect([...recorder.take()].map((v) => Math.round(v * 10))).toEqual([1, 2, 3]);
  expect(recorder.take()).toBeNull();
  recorder.begin(new Float32Array([0.5]));
  recorder.discard();
  expect(recorder.take()).toBeNull();
});

const response = (status, body) => ({ ok: status < 300, status, text: async () => JSON.stringify(body) });

test('a turn goes to the voice-note transcription endpoint as a WAV upload', async () => {
  const request = vi.fn(async () => response(200, { text: 'Hello there.', audio_signed_id: 'sig' }));
  const result = await transcribeTurn({ accountId: 'a', chatId: 'c', samples: new Float32Array(4), sampleRate: 24000, request });
  expect(result).toEqual({ text: 'Hello there.', signedId: 'sig', error: null });
  const [where, method, form] = request.mock.calls[0];
  expect([where, method]).toEqual([{ accountId: 'a', chatId: 'c' }, 'POST']);
  expect(form.get('audio').name).toBe('voice-mode-turn.wav');
  expect(form.get('audio').type).toBe('audio/wav');
});

test('a failed transcription keeps the recording only when the house says it saved it', async () => {
  const saved = vi.fn(async () =>
    response(422, { error: 'No speech detected', saved: true, retryable: true, audio_signed_id: 'kept' }),
  );
  expect(await transcribeTurn({ accountId: 'a', chatId: 'c', samples: new Float32Array(2), sampleRate: 24000, request: saved })).toEqual({
    text: '',
    signedId: 'kept',
    error: 'No speech detected',
  });
  const unreachable = vi.fn(async () => null);
  const result = await transcribeTurn({ accountId: 'a', chatId: 'c', samples: new Float32Array(2), sampleRate: 24000, request: unreachable });
  expect(result.signedId).toBeNull();
  expect(result.text).toBe('');
});

test('the clean transcript wins; the live text is the fallback, marked rough; neither means nothing', () => {
  expect(turnContent({ clean: ' Clean. ', live: 'Live.' })).toEqual({ text: 'Clean.', rough: false });
  expect(turnContent({ clean: '', live: 'Live.' })).toEqual({ text: '(rough live transcript) Live.', rough: true });
  expect(turnContent({ clean: '', live: ' ' })).toEqual({ text: '', rough: false });
});

test('a transcription that never settles is aborted and resolves as a failure; a late answer changes nothing (#761)', async () => {
  let signal;
  let answer;
  const request = vi.fn((where, method, form, options) => {
    signal = options.signal;
    return new Promise((resolve) => (answer = resolve));
  });
  const result = await transcribeTurn({
    accountId: 'a',
    chatId: 'c',
    samples: new Float32Array(2),
    sampleRate: 24000,
    request,
    timeoutMs: 20,
  });
  expect(result).toEqual({ text: '', signedId: null, error: 'The transcription took too long.' });
  expect(signal.aborted).toBe(true);
  answer(response(200, { text: 'Too late.', audio_signed_id: 'late' }));
});
