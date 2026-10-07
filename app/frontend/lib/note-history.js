// Loads a Field note's history for the History dialog. Every request carries
// a generation number; reset() and each new request bump it, and a response
// from an older generation is dropped. Without this, reading note A, closing,
// and opening B's history could let A's late response land in B's dialog.
// Each request also clears the other request's busy flag, since starting it
// cancels that one, so no button is left disabled by a request that died.

import { noteVersionsPath } from './field';

export function createNoteHistoryLoader({ fetch: fetchFn = (...args) => fetch(...args), onChange }) {
  let generation = 0;
  let controller = null;
  let state = initialState();

  function initialState() {
    return { versions: [], hasMore: false, loading: false, reading: null, readingLoading: false, error: '' };
  }

  function set(patch) {
    state = { ...state, ...patch };
    onChange?.(state);
  }

  function begin() {
    controller?.abort();
    controller = typeof AbortController === 'undefined' ? null : new AbortController();
    generation += 1;
    return { mine: generation, signal: controller?.signal };
  }

  async function getJson(url, signal) {
    const response = await fetchFn(url, { headers: { Accept: 'application/json' }, signal });
    if (!response.ok) throw new Error(String(response.status));
    return response.json();
  }

  return {
    get state() {
      return state;
    },

    // Forget everything: the dialog closed or switched to another note.
    reset() {
      controller?.abort();
      controller = null;
      generation += 1;
      state = initialState();
      onChange?.(state);
    },

    async load(accountId, noteId, { before = null } = {}) {
      const { mine, signal } = begin();
      set({ loading: true, readingLoading: false, error: '', reading: null });
      const url = noteVersionsPath(accountId, noteId) + (before ? `?before=${encodeURIComponent(before)}` : '');
      try {
        const data = await getJson(url, signal);
        if (mine !== generation) return;
        set({
          versions: before ? [...state.versions, ...data.versions] : data.versions,
          hasMore: Boolean(data.has_more),
          loading: false,
        });
      } catch {
        if (mine !== generation) return;
        set({ loading: false, error: 'The history could not be loaded.' });
      }
    },

    async read(accountId, noteId, versionId) {
      const { mine, signal } = begin();
      set({ readingLoading: true, loading: false, error: '' });
      try {
        const data = await getJson(noteVersionsPath(accountId, noteId, versionId), signal);
        if (mine !== generation) return;
        set({ reading: data.version, readingLoading: false });
      } catch {
        if (mine !== generation) return;
        set({ readingLoading: false, error: 'That version could not be loaded.' });
      }
    },

    back() {
      generation += 1;
      controller?.abort();
      set({ reading: null, readingLoading: false, loading: false, error: '' });
    },
  };
}
