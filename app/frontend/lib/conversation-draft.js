// Server revisions order writes; local copies are recovery, never authority.
// Each mounted editor gets its own copy so two tabs cannot erase each other's
// offline edits. Recovery copies are removed only after their exact bytes sync.
const PREFIX = 'conversation-draft:v1:';
export const DRAFT_LOGOUT = 'conversation-draft-logout:';
const editors = new Set();

export function registerDraftEditor(editor) {
  editors.add(editor);
  return () => editors.delete(editor);
}

function browserStorage() {
  try {
    return localStorage;
  } catch {
    return null;
  }
}

export function clearLocalDrafts(userId, storage = browserStorage()) {
  for (const editor of editors) {
    if (editor.userId === userId) {
      editor.suppressPersistence = true;
      editor.dispose();
    }
  }
  const prefix = `${PREFIX}${userId}:`;
  for (const key of Object.keys(storage)) {
    if (key.startsWith(prefix)) storage.removeItem(key);
  }
  storage.setItem(`${DRAFT_LOGOUT}${userId}`, crypto.randomUUID());
}

export class ConversationDraft {
  constructor({
    userId,
    accountId,
    chatId,
    url,
    onchange,
    storage = browserStorage(),
    request = (...args) => fetch(...args),
  }) {
    this.userId = userId;
    registerDraftEditor(this);
    this.prefix = `${PREFIX}${userId}:${accountId}:${chatId}:`;
    this.key = this.prefix + crypto.randomUUID();
    this.storage = storage;
    this.request = request;
    this.url = url;
    this.onchange = onchange;
    this.content = '';
    this.base = null;
    this.dirty = false;
    this.status = 'Loading draft…';
    this.conflict = null;
    this.storageError = false;
    this.recoveries = [];
    this.sending = false;
    this.disposed = false;
    this.localVersion = 0;
    this.readRecovery();
  }

  snapshot() {
    return {
      content: this.content,
      status: this.status,
      conflict: this.conflict,
      storageError: this.storageError,
      localSaved: this.dirty && !this.storageError,
      recoveries: this.recoveries,
    };
  }

  emit() {
    if (!this.disposed) this.onchange(this.snapshot());
  }

  readRecovery() {
    try {
      this.recoveries = Object.keys(this.storage)
        .filter((key) => key.startsWith(this.prefix))
        .map((key) => ({ key, ...JSON.parse(this.storage.getItem(key)) }))
        .filter((copy) => typeof copy.content === 'string')
        .sort((a, b) => b.at - a.at);
      const versions = new Set(this.recoveries.map((copy) => JSON.stringify([copy.content, copy.base?.revision])));
      if (versions.size === 1) this.restore(this.recoveries[0]);
    } catch {
      this.storageError = true;
    }
  }

  restore(copy) {
    this.content = copy.content;
    this.base = copy.base;
    this.dirty = true;
    this.sourceCopy = copy;
    this.localVersion++;
    this.persist();
  }

  persist() {
    if (this.suppressPersistence) return;
    try {
      if (this.dirty) {
        this.storage.setItem(this.key, JSON.stringify({ content: this.content, base: this.base, at: Date.now() }));
      } else {
        this.storage.removeItem(this.key);
      }
      this.storageError = false;
    } catch {
      this.storageError = true;
    }
  }

  removeSyncedCopy(content) {
    try {
      const superseded = new Set([content, this.sourceCopy?.content]);
      // Compare before deleting: another tab may have edited its recovery copy.
      for (const copy of this.recoveries) {
        const current = JSON.parse(this.storage.getItem(copy.key) || 'null');
        if (superseded.has(current?.content) && current?.at === copy.at) this.storage.removeItem(copy.key);
      }
      this.recoveries = this.recoveries.filter((copy) => !superseded.has(copy.content));
      this.sourceCopy = null;
    } catch {
      this.storageError = true;
    }
  }

  async api(method, body) {
    if (this.suppressPersistence) throw new Error('Signed out; reload before editing');
    const response = await this.request(this.url, {
      method,
      credentials: 'same-origin',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        'X-CSRF-Token': document.querySelector('meta[name="csrf-token"]')?.content || '',
        'X-Draft-User': this.userId,
      },
      ...(body ? { body: JSON.stringify(body) } : {}),
    });
    const data = await response.json();
    if (response.status === 409) {
      this.conflict = data.draft;
      this.status = 'Draft changed on another client';
      this.persist();
      this.emit();
      throw new Error(this.status);
    }
    if (!response.ok || !data.draft) {
      throw new Error(data.errors?.join(', ') || data.error || 'Could not sync draft');
    }
    return data.draft;
  }

  async refresh() {
    if (this.inflight || this.sending || this.disposed) return;
    let loaded = false;
    this.inflight = (async () => {
      try {
        const remote = await this.api('GET');
        loaded = true;
        if (this.dirty) {
          if (this.content === remote.content) {
            this.dirty = false;
            this.removeSyncedCopy(this.content);
          } else if (
            (this.base && this.base.revision !== remote.revision) ||
            (!this.base && (remote.revision !== 0 || remote.content !== ''))
          ) {
            this.conflict = remote;
            this.status = 'Draft changed on another client';
            return;
          }
        } else {
          this.content = remote.content;
        }
        this.base = remote;
        this.conflict = null;
        this.status = this.dirty ? 'Saving…' : 'Saved';
        this.persist();
      } catch (error) {
        this.status = `Not synced: ${error.message}`;
      } finally {
        this.emit();
      }
    })();
    await this.inflight;
    this.inflight = null;
    if (loaded && this.dirty && !this.conflict) this.schedule();
  }

  edit(content) {
    if (this.suppressPersistence) return;
    this.content = content;
    this.localVersion++;
    this.dirty = true;
    this.persist();
    this.status = this.conflict ? 'Draft changed on another client' : 'Saving…';
    this.emit();
    if (!this.sending) this.schedule();
  }

  schedule() {
    if (this.disposed || this.conflict) return;
    clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush().catch(() => {}), 400);
    this.maxTimer ||= setTimeout(() => this.flush().catch(() => {}), 2000);
  }

  clearTimers() {
    clearTimeout(this.timer);
    clearTimeout(this.maxTimer);
    this.maxTimer = null;
  }

  async flush() {
    this.clearTimers();
    while (this.inflight) await this.inflight;
    if (this.conflict) throw new Error('Resolve the draft conflict before sending');
    if (!this.base) {
      await this.refresh();
      if (!this.base) throw new Error('Draft has not synced yet; your local copy is retained');
    }
    if (!this.dirty) return;
    const content = this.content;
    this.inflight = (async () => {
      try {
        const remote = await this.api('PATCH', { content, revision: this.base.revision });
        this.base = remote;
        this.dirty = this.content !== content;
        this.removeSyncedCopy(content);
        this.persist();
        this.status = this.dirty ? 'Saving…' : 'Saved';
      } catch (error) {
        this.status = this.conflict ? error.message : `Not synced: ${error.message}`;
        throw error;
      } finally {
        this.emit();
      }
    })();
    try {
      await this.inflight;
    } finally {
      this.inflight = null;
    }
    if (this.dirty && !this.sending) this.schedule();
  }

  async resolve(useLocal) {
    const remote = this.conflict;
    if (!remote) return;
    this.base = remote;
    this.conflict = null;
    if (!useLocal) {
      this.removeSyncedCopy(this.content);
      this.content = remote.content;
      this.dirty = false;
    }
    this.persist();
    this.emit();
    if (useLocal) await this.flush();
    else this.status = 'Saved';
    this.emit();
  }

  async recover(copy) {
    // The current dirty copy remains separately stored for recovery.
    if (this.dirty) {
      this.recoveries.push({ key: this.key, content: this.content, base: this.base, at: Date.now() });
      this.persist();
    }
    this.key = this.prefix + crypto.randomUUID();
    this.restore(copy);
    await this.refresh();
  }

  async beginSend() {
    if (this.suppressPersistence) throw new Error('Signed out; reload before sending');
    await this.flush();
    if (this.conflict || this.dirty) throw new Error('Please wait for the draft to finish syncing');
    this.sending = true;
    this.clearTimers();
    return { content: this.content, revision: this.base.revision, localVersion: this.localVersion };
  }

  sent(sent, remote) {
    this.sending = false;
    this.base = remote;
    if (this.localVersion === sent.localVersion) this.content = '';
    this.dirty = this.content !== remote.content;
    this.persist();
    this.status = this.dirty ? 'Saving…' : 'Saved';
    this.emit();
    if (this.dirty) this.schedule();
  }

  failed(remote) {
    this.sending = false;
    if (remote) {
      this.conflict = remote;
      this.dirty = true;
      this.status = 'Draft changed on another client';
      this.persist();
    }
    this.emit();
    if (!this.conflict && this.dirty) this.schedule();
  }

  dispose() {
    this.disposed = true;
    this.clearTimers();
    // The local write already happened on input. Best effort server flush,
    // not a beforeunload promise or a dependency on the page remaining alive.
    if (this.dirty && this.base && !this.conflict && !this.sending && !this.suppressPersistence) {
      this.flush()
        .catch(() => {})
        .finally(() => editors.delete(this));
    } else if (!this.inflight && !this.sending) {
      editors.delete(this);
    }
  }
}
