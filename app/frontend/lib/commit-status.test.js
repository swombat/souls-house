import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { commitStatus, requestCommitStatus, resetCommitStatusesForTest } from './commit-status.svelte.js';

describe('commit status store', () => {
  beforeEach(() => {
    resetCommitStatusesForTest();
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('batches requests and keeps unknown answers unbadged', async () => {
    const fetchMock = vi.fn(async () => ({
      ok: true,
      json: async () => ({
        statuses: { '51625a7': 'deployed', '783ab2e': 'merged', abcdef1: null, '9c8b7a6': 'bogus' },
      }),
    }));
    vi.stubGlobal('fetch', fetchMock);

    ['51625a7', '783ab2e', 'abcdef1', '9c8b7a6', '51625a7'].forEach(requestCommitStatus);
    await vi.runAllTimersAsync();

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe('/admin/commit_statuses?shas=51625a7%2C783ab2e%2Cabcdef1%2C9c8b7a6');
    expect(commitStatus('51625a7')).toBe('deployed');
    expect(commitStatus('783ab2e')).toBe('merged');
    expect(commitStatus('abcdef1')).toBeNull();
    expect(commitStatus('9c8b7a6')).toBeNull();

    requestCommitStatus('51625a7');
    await vi.runAllTimersAsync();
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('a failed request leaves everything unknown', async () => {
    vi.stubGlobal(
      'fetch',
      vi.fn(async () => ({ ok: false }))
    );
    requestCommitStatus('51625a7');
    await vi.runAllTimersAsync();
    expect(commitStatus('51625a7')).toBeNull();
  });
});
