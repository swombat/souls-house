import { describe, expect, it, vi } from 'vitest';

vi.mock('$lib/voice-mode-turn-audio', async (importOriginal) => {
  const original = await importOriginal();
  return { ...original, transcribeTurn: vi.fn() };
});

import { transcribeTurn, ROUGH_MARK } from '$lib/voice-mode-turn-audio';
import { resolveTurn, settleWithin, startCleanTurn } from '$lib/voice-mode-turn-flow';

describe('startCleanTurn', () => {
  it('skips the request when the turn has no samples', async () => {
    await expect(startCleanTurn({ accountId: 'a', chatId: 'c', samples: [], sampleRate: 24_000 })).resolves.toEqual({
      text: '',
      signedId: null,
      error: null,
    });
    expect(transcribeTurn).not.toHaveBeenCalled();
  });

  it('turns a failed request into a result with the error, never a rejection', async () => {
    transcribeTurn.mockRejectedValueOnce(new Error('upload failed'));
    await expect(
      startCleanTurn({ accountId: 'a', chatId: 'c', samples: new Float32Array(10), sampleRate: 24_000 })
    ).resolves.toEqual({ text: '', signedId: null, error: 'upload failed' });
  });
});

describe('settleWithin', () => {
  it('returns the fallback when the promise is too slow or rejects', async () => {
    await expect(settleWithin(new Promise(() => {}), 5, 'late')).resolves.toBe('late');
    await expect(settleWithin(Promise.reject(new Error('no')), 50, 'failed')).resolves.toBe('failed');
    await expect(settleWithin(Promise.resolve('fast'), 50, 'late')).resolves.toBe('fast');
  });
});

describe('resolveTurn', () => {
  it('sends the clean text as soon as it is in, without waiting for the live caption', async () => {
    const onProvisional = vi.fn();
    const turn = await resolveTurn({
      transcript: new Promise(() => {}),
      clean: Promise.resolve({ text: 'Clean words.', signedId: 'sig1', error: null }),
      durationMs: 2000,
      onProvisional,
    });
    expect(turn).toEqual({ text: 'Clean words.', signedId: 'sig1', note: '' });
    expect(onProvisional).not.toHaveBeenCalled();
  });

  it('shows the live caption as provisional, then sends it marked rough when the clean text is missing', async () => {
    const onProvisional = vi.fn();
    const turn = await resolveTurn({
      transcript: Promise.resolve('Rough words'),
      clean: Promise.resolve({ text: '', signedId: 'sig2', error: 'timeout' }),
      durationMs: 2000,
      onProvisional,
    });
    expect(onProvisional).toHaveBeenCalledWith('Rough words');
    expect(turn.signedId).toBe('sig2');
    expect(turn.text).toContain('Rough words');
    expect(turn.text).toContain(ROUGH_MARK);
  });

  it('falls back to the caption when the clean request never settles', async () => {
    const turn = await resolveTurn({
      transcript: Promise.resolve('Still here'),
      clean: new Promise(() => {}),
      durationMs: 1000,
      backstopMs: 5,
    });
    expect(turn.text).toContain('Still here');
    expect(turn.signedId).toBeNull();
  });

  it('explains a turn with no words', async () => {
    const silent = await resolveTurn({
      transcript: Promise.resolve(''),
      clean: Promise.resolve({ text: '', signedId: null, error: null }),
      durationMs: 3200,
    });
    expect(silent).toEqual({ text: '', signedId: null, note: 'Heard 3s of sound but no words.' });
    const failed = await resolveTurn({
      transcript: Promise.reject(new Error('socket closed')),
      clean: Promise.resolve({ text: '', signedId: null, error: 'timeout' }),
      durationMs: 3200,
    });
    expect(failed).toEqual({ text: '', signedId: null, note: 'socket closed' });
  });
});
