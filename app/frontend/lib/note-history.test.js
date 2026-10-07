import { describe, expect, it } from 'vitest';
import { createNoteHistoryLoader } from './note-history';

// A fetch whose responses resolve only when the test says so, to replay
// requests finishing out of order.
function deferredFetch() {
  const pending = [];
  const fetch = (url) =>
    new Promise((resolve) => {
      pending.push({ url, respond: (body) => resolve({ ok: true, json: async () => body }) });
    });
  return { fetch, pending };
}

const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

describe('note history loader', () => {
  it("drops note A's late version when B's history is open", async () => {
    const { fetch, pending } = deferredFetch();
    const loader = createNoteHistoryLoader({ fetch });

    loader.read('acc', 'A', 'vA'); // start reading A
    loader.reset(); // dialog closes
    loader.load('acc', 'B'); // B's history opens

    pending[1].respond({ versions: [{ id: 'vB', revision: 1 }], has_more: false });
    pending[0].respond({ version: { id: 'vA', content: 'text from A' } }); // A arrives late
    await flush();

    expect(pending[0].url).toBe('/accounts/acc/whiteboards/A/versions/vA');
    expect(loader.state.reading).toBeNull();
    expect(loader.state.versions.map((v) => v.id)).toEqual(['vB']);
  });

  it("drops note A's late list when B's history is open", async () => {
    const { fetch, pending } = deferredFetch();
    const loader = createNoteHistoryLoader({ fetch });

    loader.load('acc', 'A');
    loader.reset();
    loader.load('acc', 'B');

    pending[1].respond({ versions: [{ id: 'vB' }], has_more: false });
    pending[0].respond({ versions: [{ id: 'vA' }], has_more: true });
    await flush();

    expect(loader.state.versions.map((v) => v.id)).toEqual(['vB']);
    expect(loader.state.hasMore).toBe(false);
  });

  it('going back to the list drops a read still in flight', async () => {
    const { fetch, pending } = deferredFetch();
    const loader = createNoteHistoryLoader({ fetch });

    loader.read('acc', 'A', 'v1');
    loader.back();
    pending[0].respond({ version: { id: 'v1', content: 'late' } });
    await flush();

    expect(loader.state.reading).toBeNull();
    expect(loader.state.readingLoading).toBe(false);
  });

  it('appends an older page after the cursor', async () => {
    const { fetch, pending } = deferredFetch();
    const loader = createNoteHistoryLoader({ fetch });

    loader.load('acc', 'A');
    pending[0].respond({ versions: [{ id: 'v3' }, { id: 'v2' }], has_more: true });
    await flush();
    loader.load('acc', 'A', { before: 'v2' });
    pending[1].respond({ versions: [{ id: 'v1' }], has_more: false });
    await flush();

    expect(pending[1].url).toBe('/accounts/acc/whiteboards/A/versions?before=v2');
    expect(loader.state.versions.map((v) => v.id)).toEqual(['v3', 'v2', 'v1']);
    expect(loader.state.hasMore).toBe(false);
  });

  it('a read cancelled by Older versions leaves the version rows enabled', async () => {
    const { fetch, pending } = deferredFetch();
    const loader = createNoteHistoryLoader({ fetch });

    loader.load('acc', 'A');
    pending[0].respond({ versions: [{ id: 'v3' }, { id: 'v2' }], has_more: true });
    await flush();
    loader.read('acc', 'A', 'v3');
    loader.load('acc', 'A', { before: 'v2' });
    pending[1].respond({ version: { id: 'v3', content: 'late' } });
    pending[2].respond({ versions: [{ id: 'v1' }], has_more: false });
    await flush();

    expect(loader.state.readingLoading).toBe(false);
    expect(loader.state.loading).toBe(false);
    expect(loader.state.reading).toBeNull();
    expect(loader.state.versions.map((v) => v.id)).toEqual(['v3', 'v2', 'v1']);
  });

  it('Older versions cancelled by a read and then Back leaves Older versions enabled', async () => {
    const { fetch, pending } = deferredFetch();
    const loader = createNoteHistoryLoader({ fetch });

    loader.load('acc', 'A');
    pending[0].respond({ versions: [{ id: 'v3' }, { id: 'v2' }], has_more: true });
    await flush();
    loader.load('acc', 'A', { before: 'v2' });
    loader.read('acc', 'A', 'v3');
    expect(loader.state.loading).toBe(false);
    loader.back();
    pending[1].respond({ versions: [{ id: 'v1' }], has_more: false });
    pending[2].respond({ version: { id: 'v3', content: 'late' } });
    await flush();

    expect(loader.state.loading).toBe(false);
    expect(loader.state.readingLoading).toBe(false);
    expect(loader.state.hasMore).toBe(true);
    expect(loader.state.versions.map((v) => v.id)).toEqual(['v3', 'v2']);
  });
});
