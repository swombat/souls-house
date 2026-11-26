import { DRAFT_LOGOUT, registerDraftEditor } from './conversation-draft';

function browserStorage() {
  try {
    return localStorage;
  } catch {
    return null;
  }
}

function defaultSelectedAgentIds(agents) {
  return agents
    .filter((agent) => agent.paused !== true && agent.invite_to_new_conversations !== false)
    .map((agent) => agent.id);
}

// One browser-local slot, not the revisioned/server-synced chat draft protocol.
export class NewConversationDraft {
  constructor({ userId, accountId, agents, onchange, storage = browserStorage() }) {
    this.userId = userId;
    this.key = userId ? `conversation-draft:v1:${userId}:${accountId}:new` : null;
    this.storage = storage;
    this.onchange = onchange;
    this.storageError = false;
    this.customAgentSelection = false;
    this.content = {
      message: '',
      title: '',
      selectedAgentIds: defaultSelectedAgentIds(agents),
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
          !saved.selectedAgentIds.every((id) => typeof id === 'string') ||
          ('customAgentSelection' in saved && typeof saved.customAgentSelection !== 'boolean')
        ) {
          throw new Error('Invalid draft');
        }
        const byId = new Map(agents.map((agent) => [agent.id, agent]));
        let selectedAgentIds;
        if (saved.customAgentSelection === true) {
          this.customAgentSelection = true;
          selectedAgentIds = saved.selectedAgentIds.filter((id) => byId.has(id));
        } else if (saved.customAgentSelection === false) {
          this.customAgentSelection = false;
          selectedAgentIds = defaultSelectedAgentIds(agents);
        } else {
          // Legacy drafts predating selection provenance keep stored choices except opted-out guests.
          this.customAgentSelection = null;
          selectedAgentIds = saved.selectedAgentIds.filter((id) => {
            const agent = byId.get(id);
            return Boolean(agent && agent.invite_to_new_conversations !== false);
          });
        }
        this.content = {
          message: saved.message,
          title: saved.title,
          selectedAgentIds,
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
    const raw = JSON.stringify({
      ...this.content,
      ...(typeof this.customAgentSelection === 'boolean' ? { customAgentSelection: this.customAgentSelection } : {}),
      version: crypto.randomUUID(),
    });
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
    if ('selectedAgentIds' in values) {
      this.customAgentSelection = true;
    }
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
