import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { NewConversationDraft } from './new-conversation-draft';
import { clearLocalDrafts, DRAFT_LOGOUT } from './conversation-draft';

describe('browser-local new conversation draft', () => {
  let editors;
  const create = (options = {}) => {
    const editor = new NewConversationDraft({
      userId: 'user',
      accountId: 'account',
      agents: [{ id: 'one' }, { id: 'paused', paused: true }],
      onchange: vi.fn(),
      ...options,
    });
    editors.push(editor);
    return editor;
  };
  beforeEach(() => {
    localStorage.clear();
    editors = [];
  });
  afterEach(() => editors.forEach((editor) => editor.dispose()));

  it('restores before writes and retains title, message and selected paused residents', () => {
    const first = create();
    expect(first.content.selectedAgentIds).toEqual(['one']);
    first.edit({ message: 'Text', title: 'Title', selectedAgentIds: ['paused'] });
    const raw = localStorage.getItem(first.key);
    const second = create();
    expect(second.content).toMatchObject({ message: 'Text', title: 'Title', selectedAgentIds: ['paused'] });
    expect(localStorage.getItem(first.key)).toBe(raw);
    expect(Object.keys(localStorage).filter((key) => key.startsWith('conversation-draft:v1:'))).toHaveLength(1);
  });

  it('filters missing IDs and does not select newly available agents or replace an empty selection', () => {
    create().edit({ selectedAgentIds: ['gone'] });
    expect(create().content.selectedAgentIds).toEqual([]);
    create().edit({ selectedAgentIds: [] });
    expect(create({ agents: [{ id: 'new' }] }).content.selectedAgentIds).toEqual([]);
  });

  it('uses last local write wins and isolates users and accounts', () => {
    const first = create();
    const second = create();
    first.edit({ message: 'First' });
    second.edit({ message: 'Second' });
    expect(create().content.message).toBe('Second');
    expect(create({ accountId: 'other' }).content.message).toBe('');
    expect(create({ userId: 'other' }).content.message).toBe('');
  });

  it('does not access or persist storage when unauthenticated', () => {
    const storage = { getItem: vi.fn(), setItem: vi.fn(), removeItem: vi.fn() };
    const editor = create({ userId: null, storage });
    editor.edit({ message: 'Anonymous' });
    editor.beginSend();
    expect(storage.getItem).not.toHaveBeenCalled();
    expect(storage.setItem).not.toHaveBeenCalled();
  });

  it('restores the uncertain submission nonce, but creates a fresh nonce on retry', () => {
    const editor = create();
    editor.edit({ message: 'Maybe sent' });
    const first = editor.beginSend();
    const restored = create();
    expect(restored.content.submissionId).toBe(first.submissionId);
    const retry = restored.beginSend();
    expect(retry.submissionId).not.toBe(first.submissionId);
    expect(restored.sent(first, first.submissionId)).toBe(false);
    expect(localStorage.getItem(editor.key)).toBe(retry.raw);
  });

  it('clears only with a matching receipt and the exact serialized submitted copy', () => {
    const editor = create();
    editor.edit({ message: 'Sent' });
    const submitted = editor.beginSend();
    expect(editor.sent(submitted, undefined)).toBe(false);
    expect(editor.sent(submitted, 'other')).toBe(false);
    expect(localStorage.getItem(editor.key)).toBe(submitted.raw);
    expect(editor.sent(submitted, submitted.submissionId)).toBe(true);
    expect(localStorage.getItem(editor.key)).toBeNull();
  });

  it('retains different or newer same-text tab writes after success', () => {
    const editor = create();
    editor.edit({ message: 'Same' });
    const submitted = editor.beginSend();
    create().edit({ message: 'Same' });
    const newer = localStorage.getItem(editor.key);
    editor.sent(submitted, submitted.submissionId);
    expect(localStorage.getItem(editor.key)).toBe(newer);
    expect(create().content.message).toBe('Same');
  });

  it('does not clear new edits in the submitting editor', () => {
    const editor = create();
    editor.edit({ message: 'First' });
    const submitted = editor.beginSend();
    editor.edit({ message: 'Second' });
    expect(editor.sent(submitted, submitted.submissionId)).toBe(false);
    expect(create().content.message).toBe('Second');
  });

  it('allows an unmounted send receipt but never persists late input or transcription', () => {
    const editor = create();
    editor.edit({ message: 'Submit' });
    const submitted = editor.beginSend();
    editor.dispose();
    editor.edit({ message: 'Late transcription' });
    expect(() => editor.beginSend()).toThrow('Composer closed');
    expect(localStorage.getItem(editor.key)).toBe(submitted.raw);
    expect(editor.sent(submitted, submitted.submissionId)).toBe(true);
    expect(localStorage.getItem(editor.key)).toBeNull();
  });

  it('shares logout cleanup and suppresses late callbacks even with blocked storage', () => {
    const first = create();
    const other = create({ userId: 'other' });
    first.edit({ message: 'Private' });
    other.edit({ message: 'Other' });
    clearLocalDrafts('user');
    first.edit({ message: 'Late' });
    expect(localStorage.getItem(first.key)).toBeNull();
    expect(create({ userId: 'other' }).content.message).toBe('Other');
    const blocked = create({ storage: null });
    expect(() => clearLocalDrafts('user', null)).toThrow();
    blocked.edit({ message: 'Late' });
    expect(blocked.suppressPersistence).toBe(true);
  });

  it('suppresses stale tabs on logout events and checks the marker before late writes', () => {
    const editor = create();
    localStorage.setItem(`${DRAFT_LOGOUT}user`, 'logout');
    editor.edit({ message: 'Late write before event' });
    expect(localStorage.getItem(editor.key)).toBeNull();
    const second = create();
    window.dispatchEvent(new StorageEvent('storage', { key: `${DRAFT_LOGOUT}user`, newValue: 'again' }));
    expect(second.suppressPersistence).toBe(true);
  });

  it('warns on read/write failures without losing current text', () => {
    const editor = create({ storage: null });
    expect(editor.storageError).toBe(true);
    editor.edit({ message: 'Keep in memory' });
    const submitted = editor.beginSend();
    expect(editor.storageError).toBe(true);
    expect(editor.content.message).toBe('Keep in memory');
    expect(submitted.raw).toBeNull();
  });

  it('warns about invalid stored data instead of silently overwriting it on mount', () => {
    const key = create().key;
    localStorage.setItem(key, '{invalid');
    expect(create().storageError).toBe(true);
    expect(localStorage.getItem(key)).toBe('{invalid');
  });
});
