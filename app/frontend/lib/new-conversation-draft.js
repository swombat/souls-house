import { DRAFT_LOGOUT, registerDraftEditor } from './conversation-draft';

function browserStorage() {
  try {
    return localStorage;
  } catch {
    return null;
  }
}

// One browser-local slot, not the revisioned/server-synced chat draft protocol.
export class NewConversationDraft {
  constructor({ userId, accountId, agents, onchange, storage = browserStorage() }) {
    this.userId = userId;
    this.key = userId ? `conversation-draft:v1:${userId}:${accountId}:new` : null;
    this.storage = storage;
    this.onchange = onchange;
    this.storageError = false;
    this.content = {
      message: '',
      title: '',
      selectedAgentIds: agents.filter((agent) => agent.paused !== true).map((agent) => agent.id),
      submissionId: null,
    };
    if (!this.key) return;
    this.unregister = registerDraftEditor(this);
    try {
      this.logoutMarker = storage.getItem(`${DRAFT_LOGOUT}${userId}`);
      const raw = storage.getItem(this.key);
      if (raw) {
        const saved = JSON.parse(raw);
        if (
          typeof saved.message !== 'string' ||
          typeof saved.title !== 'string' ||
          !Array.isArray(saved.selectedAgentIds) ||
          !saved.selectedAgentIds.every((id) => typeof id === 'string')
        ) {
          throw new Error('Invalid draft');
        }
        const available = new Set(agents.map((agent) => agent.id));
        this.content = {
          message: saved.message,
          title: saved.title,
          selectedAgentIds: saved.selectedAgentIds.filter((id) => available.has(id)),
          submissionId: typeof saved.submissionId === 'string' ? saved.submissionId : null,
        };
      }
    } catch {
      this.storageError = true;
    }
    this.onStorage = (event) => {
      if (event.key === `${DRAFT_LOGOUT}${userId}` && event.newValue !== this.logoutMarker) {
        this.suppressPersistence = true;
        this.dispose();
      }
    };
    window.addEventListener('storage', this.onStorage);
  }

  snapshot() {
    return { ...this.content, storageError: this.storageError };
  }

  emit() {
    this.onchange?.(this.snapshot());
  }

  canWrite() {
    if (!this.key || this.suppressPersistence) return false;
    try {
      if (this.storage.getItem(`${DRAFT_LOGOUT}${this.userId}`) !== this.logoutMarker) {
        this.suppressPersistence = true;
        return false;
      }
    } catch {
      this.storageError = true;
      // Keep editing/sending usable even when storage is blocked.
    }
    return true;
  }

  persist() {
    if (!this.canWrite()) return null;
    const raw = JSON.stringify({ ...this.content, version: crypto.randomUUID() });
    try {
      this.storage.setItem(this.key, raw);
      this.storageError = false;
      return raw;
    } catch {
      this.storageError = true;
      return null;
    }
  }

  edit(values) {
    if (this.disposed || this.suppressPersistence) return;
    this.content = { ...this.content, ...values, submissionId: null };
    this.persist();
    this.emit();
  }

  beginSend() {
    if (this.disposed) throw new Error('Composer closed; reload before sending');
    if (!this.canWrite() && this.key) throw new Error('Signed out; reload before sending');
    this.content = { ...this.content, submissionId: crypto.randomUUID() };
    const raw = this.persist();
    this.emit();
    return { ...this.content, raw };
  }

  sent(submitted, receipt) {
    if (receipt !== submitted.submissionId || (this.key && !this.canWrite())) return false;
    // Do not rewrite the slot: a different/newer tab owns whatever is there now.
    try {
      if (submitted.raw && this.storage.getItem(this.key) === submitted.raw) {
        this.storage.removeItem(this.key);
      }
    } catch {
      this.storageError = true;
    }
    if (this.content.submissionId !== submitted.submissionId) {
      this.emit();
      return false;
    }
    this.content = { ...this.content, message: '', title: '', submissionId: null };
    this.emit();
    return true;
  }

  dispose() {
    this.disposed = true;
    this.unregister?.();
    window.removeEventListener('storage', this.onStorage);
  }
}
