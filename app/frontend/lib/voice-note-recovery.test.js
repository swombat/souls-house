import { describe, expect, it } from 'vitest';
import {
  clearRecovery,
  loadRecovery,
  readTranscription,
  recoveryKey,
  saveRecovery,
  withTranscript,
} from './voice-note-recovery';

class MemoryStorage {
  constructor() {
    this.map = new Map();
  }
  getItem(key) {
    return this.map.has(key) ? this.map.get(key) : null;
  }
  setItem(key, value) {
    this.map.set(key, String(value));
  }
  removeItem(key) {
    this.map.delete(key);
  }
}

const scope = { userId: 'u1', accountId: 'a1', chatId: 'c1' };
const json = (status, body) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });

describe('voice note recovery storage', () => {
  it('keys by user, account and chat, with new conversations kept apart', () => {
    expect(recoveryKey(scope)).toBe('voice-note-recovery:v1:u1:a1:c1');
    expect(recoveryKey({ ...scope, chatId: null })).toBe('voice-note-recovery:v1:u1:a1:new');
    expect(recoveryKey({ ...scope, userId: 'u2' })).not.toBe(recoveryKey(scope));
  });

  it('round-trips a saved recording and reports expiry', () => {
    const storage = new MemoryStorage();
    const expiresAt = '2026-10-25T12:00:00Z';
    expect(saveRecovery(scope, { signedId: 's1', error: 'Timeout', expiresAt }, storage)).toBe(true);

    expect(loadRecovery(scope, { storage, now: Date.parse('2026-10-20T00:00:00Z') })).toEqual({
      signedId: 's1',
      error: 'Timeout',
      expiresAt,
      expired: false,
    });
    expect(loadRecovery(scope, { storage, now: Date.parse('2026-10-26T00:00:00Z') }).expired).toBe(true);
    expect(loadRecovery({ ...scope, chatId: 'c2' }, { storage })).toBeNull();

    clearRecovery(scope, storage);
    expect(loadRecovery(scope, { storage })).toBeNull();
  });

  it('says so when storage refuses, so the caller keeps its leave warning', () => {
    const full = new MemoryStorage();
    full.setItem = () => {
      throw new DOMException('quota', 'QuotaExceededError');
    };
    expect(saveRecovery(scope, { signedId: 's1' }, full)).toBe(false);
    expect(saveRecovery(scope, { signedId: 's1' }, null)).toBe(false);
    expect(loadRecovery(scope, { storage: null })).toBeNull();
  });

  it('removes corrupt entries instead of offering a broken retry', () => {
    const storage = new MemoryStorage();
    storage.setItem(recoveryKey(scope), '{not json');
    expect(loadRecovery(scope, { storage })).toBeNull();
    expect(storage.getItem(recoveryKey(scope))).toBeNull();

    storage.setItem(recoveryKey(scope), JSON.stringify({ signedId: 42 }));
    expect(loadRecovery(scope, { storage })).toBeNull();
  });
});

describe('reading transcription answers', () => {
  it('returns text on success', async () => {
    expect(await readTranscription(json(200, { text: 'Hello', audio_signed_id: 's1' }))).toEqual({
      ok: true,
      text: 'Hello',
      signedId: 's1',
    });
  });

  it('distinguishes saved, unsaved and gone from the app', async () => {
    const saved = await readTranscription(
      json(422, { error: 'No speech detected', saved: true, retryable: true, audio_signed_id: 's1', expires_at: 'x' })
    );
    expect(saved).toMatchObject({
      ok: false,
      saved: 'saved',
      signedId: 's1',
      error: 'No speech detected',
      retryable: true,
    });

    const unsaved = await readTranscription(json(503, { error: 'not saved', saved: false, retryable: true }));
    expect(unsaved).toMatchObject({ saved: 'unsaved', retryable: true });

    const gone = await readTranscription(json(404, { error: 'gone', saved: false, retryable: false }), {
      retrying: true,
    });
    expect(gone).toMatchObject({ saved: 'gone' });
  });

  it('does not claim nothing was stored when the answer is not the app’s', async () => {
    const proxy = await readTranscription(new Response('<html>Bad gateway</html>', { status: 502 }));
    expect(proxy.saved).toBe('unconfirmed');
    expect(proxy.error).toContain('HTTP 502');
    expect(proxy.error).not.toMatch(/network error/i);

    const lost = await readTranscription(null);
    expect(lost.saved).toBe('unconfirmed');
    expect(lost.error).toContain('not confirmed');

    const tooLarge = await readTranscription(new Response('too big', { status: 413 }));
    expect(tooLarge).toMatchObject({ saved: 'unsaved', retryable: false });
  });

  it('keeps a saved recording saved when a retry cannot reach the app', async () => {
    expect((await readTranscription(null, { retrying: true })).saved).toBe('saved');
    expect((await readTranscription(new Response('', { status: 504 }), { retrying: true })).saved).toBe('saved');
  });
});

describe('placing a retried transcript', () => {
  it('fills an empty composer, keeps an identical one, and puts typed text first', () => {
    expect(withTranscript('', 'Hello')).toBe('Hello');
    expect(withTranscript('   ', 'Hello')).toBe('Hello');
    expect(withTranscript('Hello', 'Hello')).toBe('Hello');
    expect(withTranscript('Typed first  ', 'Hello')).toBe('Typed first\n\nHello');
  });
});
