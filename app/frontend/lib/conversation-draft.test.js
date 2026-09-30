import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { ConversationDraft, clearLocalDrafts } from './conversation-draft';

describe('private conversation drafts', () => {
  let remote, request, editors;
  const create = (options = {}) => {
    const editor = new ConversationDraft({
      userId: 'user',
      accountId: 'account',
      chatId: 'room',
      url: '/draft',
      onchange: vi.fn(),
      request,
      ...options,
    });
    editors.push(editor);
    return editor;
  };
  beforeEach(() => {
    localStorage.clear();
    vi.useFakeTimers();
    editors = [];
    remote = { content: '', revision: 0 };
    request = vi.fn(async (_url, options) => {
      if (options.method === 'PATCH') {
        const body = JSON.parse(options.body);
        if (body.revision !== remote.revision) {
          return { status: 409, ok: false, json: async () => ({ draft: { ...remote } }) };
        }
        remote = { content: body.content, revision: remote.revision + 1 };
      }
      return { status: 200, ok: true, json: async () => ({ draft: { ...remote } }) };
    });
  });
  afterEach(() => {
    for (const editor of editors) {
      editor.suppressPersistence = true;
      editor.dispose();
    }
    vi.useRealTimers();
  });

  it('persists input synchronously and restores before network returns', () => {
    const first = create();
    first.edit('careful comments');
    const restored = create();
    expect(restored.content).toBe('careful comments');
    expect(remote.content).toBe('');
    const reloadedAgain = create();
    expect(reloadedAgain.content).toBe('careful comments');
  });

  it('does not leave obsolete recovery copies after editing a restored draft', async () => {
    const first = create();
    await first.refresh();
    first.edit('original');
    const restored = create();
    restored.edit('revised');
    await restored.flush();
    expect(create().recoveries).toHaveLength(0);
  });

  it('does not spin network retries when an initial offline restore cannot load', async () => {
    create().edit('offline');
    const editor = create({ request: vi.fn().mockRejectedValue(new Error('offline')) });
    await editor.refresh();
    // The first editor is not part of this restore.
    editors[0].clearTimers();
    await vi.advanceTimersByTimeAsync(10_000);
    expect(editor.request).toHaveBeenCalledTimes(1);
    expect(editor.content).toBe('offline');
  });

  it('keeps a conflicted send locally even after a refresh', async () => {
    const editor = create();
    await editor.refresh();
    editor.edit('my send');
    await editor.beginSend();
    remote = { content: 'other client changed it', revision: 2 };
    editor.failed(remote);
    await editor.refresh();
    expect(editor.content).toBe('my send');
    expect(editor.conflict).toEqual(remote);
    expect(localStorage.getItem(editor.key)).toContain('my send');
  });

  it('syncs and retrieves on a client with no shared browser storage', async () => {
    const first = create();
    await first.refresh();
    first.edit('phone draft');
    await first.flush();
    localStorage.clear();
    const second = create();
    await second.refresh();
    expect(second.content).toBe('phone draft');
    expect(second.dirty).toBe(false);
  });

  it('preserves offline writing and shows a conflict against newer server text', async () => {
    const editor = create();
    await editor.refresh();
    editor.edit('my text');
    remote = { content: 'other device', revision: 1 };
    await expect(editor.flush()).rejects.toThrow();
    expect(editor.content).toBe('my text');
    expect(editor.conflict.content).toBe('other device');
    expect(localStorage.getItem(editor.key)).toContain('my text');
    await editor.resolve(true);
    expect(remote.content).toBe('my text');
    expect(remote.revision).toBe(2);
  });

  it('does not resurrect sent text from a stale recovery copy', async () => {
    const first = create();
    await first.refresh();
    first.edit('sent elsewhere');
    remote = { content: '', revision: 2 };
    const restored = create();
    await restored.refresh();
    expect(restored.conflict).toEqual(remote);
    expect(restored.content).toBe('sent elsewhere');
    expect(request.mock.calls.filter(([, o]) => o.method === 'PATCH')).toHaveLength(0);
  });

  it('retains typing during send and rebases onto the consumed revision', async () => {
    const editor = create();
    await editor.refresh();
    editor.edit('first message');
    const sent = await editor.beginSend();
    editor.edit('next message');
    await vi.advanceTimersByTimeAsync(2500);
    expect(remote.content).toBe('first message');
    remote = { content: '', revision: 2 };
    editor.sent(sent, remote);
    expect(editor.content).toBe('next message');
    await editor.flush();
    expect(remote).toEqual({ content: 'next message', revision: 3 });
  });

  it('keeps the draft after send failure and clears only acknowledged success', async () => {
    const editor = create();
    await editor.refresh();
    editor.edit('keep me');
    const sent = await editor.beginSend();
    editor.failed();
    expect(editor.content).toBe('keep me');
    editor.sent(sent, { content: '', revision: 2 });
    expect(editor.content).toBe('');
    expect(localStorage.getItem(editor.key)).toBeNull();
  });

  it('serializes overlapping saves and never loses edits made in flight', async () => {
    let release;
    const originalRequest = request;
    request = vi.fn(async (...args) => {
      if (args[1].method === 'PATCH' && !release) await new Promise((r) => (release = r));
      return originalRequest(...args);
    });
    const editor = create();
    await editor.refresh();
    editor.edit('first');
    const first = editor.flush();
    editor.edit('second');
    const second = editor.flush();
    release();
    await Promise.all([first, second]);
    expect(remote.content).toBe('second');
    expect(editor.conflict).toBeNull();
  });

  it('warns when local storage is unavailable, while still saving remotely', async () => {
    const storage = {
      setItem: () => {
        throw new Error('quota');
      },
      removeItem: () => {},
    };
    const editor = create({ storage });
    await editor.refresh();
    editor.edit('important');
    expect(editor.storageError).toBe(true);
    await editor.flush();
    expect(remote.content).toBe('important');
  });

  it('isolates rooms and users and clears only the logging-out user', () => {
    const first = create();
    first.edit('one');
    const other = create({ userId: 'other' });
    other.edit('two');
    const room = create({ chatId: 'other-room' });
    expect(room.content).toBe('');
    clearLocalDrafts('user');
    first.edit('late callback');
    expect(localStorage.getItem(first.key)).toBeNull();
    expect(localStorage.getItem(other.key)).toContain('two');
  });

  it('periodically saves during continuous typing', async () => {
    const editor = create();
    await editor.refresh();
    for (let i = 0; i < 12; i++) {
      editor.edit(`text ${i}`);
      await vi.advanceTimersByTimeAsync(200);
    }
    expect(remote.revision).toBeGreaterThan(0);
  });
});
