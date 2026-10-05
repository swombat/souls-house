import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
  commitStatus,
  requestCommitStatus,
  watchCommitStatus,
  resetCommitStatusesForTest,
} from './commit-status.svelte.js';

const REV_A = 'aaa:mmm';

function answering(responses) {
  // Each call takes the next response; the last one repeats.
  let i = 0;
  return vi.fn(async () => {
    const next = responses[Math.min(i++, responses.length - 1)];
    if (next instanceof Error) throw next;
    if (next === 'fail') return { ok: false };
    return { ok: true, json: async () => next };
  });
}

describe('commit status store', () => {
  beforeEach(() => {
    resetCommitStatusesForTest();
    vi.useFakeTimers();
  });

  afterEach(() => {
    resetCommitStatusesForTest();
    vi.useRealTimers();
    vi.unstubAllGlobals();
  });

  it('batches requests and keeps unknown answers unbadged', async () => {
    const fetchMock = answering([
      {
        statuses: { '51625a7': 'deployed', '783ab2e': 'merged', abcdef1: null, '9c8b7a6': 'bogus' },
        revision: REV_A,
      },
    ]);
    vi.stubGlobal('fetch', fetchMock);

    ['51625a7', '783ab2e', 'abcdef1', '9c8b7a6', '51625a7'].forEach(requestCommitStatus);
    await vi.advanceTimersByTimeAsync(100);

    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe('/admin/commit_statuses?shas=51625a7%2C783ab2e%2Cabcdef1%2C9c8b7a6');
    expect(commitStatus('51625a7')).toBe('deployed');
    expect(commitStatus('783ab2e')).toBe('merged');
    expect(commitStatus('abcdef1')).toBeNull();
    expect(commitStatus('9c8b7a6')).toBeNull();

    requestCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it('a failed request leaves everything unknown', async () => {
    vi.stubGlobal('fetch', answering(['fail']));
    requestCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    expect(commitStatus('51625a7')).toBeNull();
  });

  it('a mounted badge is refreshed, and follows a rollback', async () => {
    const fetchMock = answering([
      { statuses: { '51625a7': 'deployed' }, revision: REV_A },
      { statuses: { '51625a7': 'merged' }, revision: 'bbb:mmm' },
    ]);
    vi.stubGlobal('fetch', fetchMock);

    const stop = watchCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    expect(commitStatus('51625a7')).toBe('deployed');

    await vi.advanceTimersByTimeAsync(4 * 60 * 1000);
    expect(fetchMock.mock.calls.length).toBeGreaterThanOrEqual(2);
    expect(commitStatus('51625a7')).toBe('merged');
    stop();
  });

  it('a failed refresh of a mounted badge clears it instead of keeping the old answer', async () => {
    vi.stubGlobal(
      'fetch',
      answering([{ statuses: { '51625a7': 'deployed' }, revision: REV_A }, 'fail'])
    );

    const stop = watchCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    expect(commitStatus('51625a7')).toBe('deployed');

    await vi.advanceTimersByTimeAsync(4 * 60 * 1000);
    expect(commitStatus('51625a7')).toBeNull();
    stop();
  });

  it('a network error on refresh clears the badge too', async () => {
    vi.stubGlobal(
      'fetch',
      answering([{ statuses: { '51625a7': 'deployed' }, revision: REV_A }, new TypeError('offline')])
    );

    const stop = watchCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    await vi.advanceTimersByTimeAsync(4 * 60 * 1000);
    expect(commitStatus('51625a7')).toBeNull();
    stop();
  });

  it('a known answer expires even when no refresh lands', async () => {
    let resolveSecond;
    const fetchMock = vi
      .fn()
      .mockResolvedValueOnce({ ok: true, json: async () => ({ statuses: { '51625a7': 'deployed' }, revision: REV_A }) })
      .mockImplementation(() => new Promise((resolve) => (resolveSecond = resolve)));
    vi.stubGlobal('fetch', fetchMock);

    const stop = watchCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    expect(commitStatus('51625a7')).toBe('deployed');

    // The refresh hangs; the old rocket must not stay up past its expiry.
    await vi.advanceTimersByTimeAsync(7 * 60 * 1000);
    expect(commitStatus('51625a7')).toBeNull();
    stop();
    resolveSecond?.({ ok: false });
  });

  it('a new running revision drops answers measured against the old one', async () => {
    const fetchMock = answering([
      { statuses: { '51625a7': 'deployed' }, revision: REV_A },
      { statuses: { '783ab2e': 'merged' }, revision: 'bbb:mmm' },
      { statuses: { '51625a7': 'merged' }, revision: 'bbb:mmm' },
    ]);
    vi.stubGlobal('fetch', fetchMock);

    const stopA = watchCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    expect(commitStatus('51625a7')).toBe('deployed');

    // Another reference mounts, and its answer reveals a new deployment.
    const stopB = watchCommitStatus('783ab2e');
    await vi.advanceTimersByTimeAsync(300);
    expect(commitStatus('51625a7')).toBe('merged');
    expect(fetchMock).toHaveBeenCalledTimes(3);
    stopA();
    stopB();
  });

  it('stops polling once nothing is watched', async () => {
    const fetchMock = answering([{ statuses: { '51625a7': 'merged' }, revision: REV_A }]);
    vi.stubGlobal('fetch', fetchMock);

    const stop = watchCommitStatus('51625a7');
    await vi.advanceTimersByTimeAsync(100);
    stop();
    await vi.advanceTimersByTimeAsync(30 * 60 * 1000);
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });
});
