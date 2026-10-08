import { describe, expect, it } from 'vitest';
import {
  runLabel,
  shouldPoll,
  applyPollResult,
  classifyResponse,
  expiryWarning,
  MAX_CONSECUTIVE_FAILURES,
} from './deploys.js';

const running = { id: 1, status: 'in_progress' };
const done = { id: 1, status: 'completed', conclusion: 'success' };
const fresh = (runs = []) => ({ runs, error: null, failures: 0, stopped: false });

describe('runLabel', () => {
  it('labels in-flight and finished runs', () => {
    expect(runLabel({ status: 'queued' })).toBe('… queued');
    expect(runLabel({ status: 'in_progress' })).toBe('… running');
    expect(runLabel(done)).toBe('✓ success');
    expect(runLabel({ status: 'completed', conclusion: 'failure' })).toBe('✗ failed');
  });
});

describe('runLabel for automatic deploys', () => {
  const auto = (outcome) => ({ status: 'completed', conclusion: 'success', workflow: 'rails_auto', outcome });
  it('says what shipped, not just that the workflow succeeded', () => {
    expect(runLabel(auto('deployed'))).toBe('✓ deployed');
    expect(runLabel(auto('superseded'))).toBe('– master moved on, nothing deployed');
    expect(runLabel(auto('not_deployed'))).toBe('– not deployed');
    expect(runLabel(auto(undefined))).toBe('✓ finished (outcome unknown)');
    expect(runLabel({ ...auto(undefined), conclusion: 'failure' })).toBe('✗ failed');
  });
});

describe('shouldPoll', () => {
  it('polls while a run is unfinished', () => {
    expect(shouldPoll(fresh([running]), 0, 1000)).toBe(true);
    expect(shouldPoll(fresh([done]), 0, 1000)).toBe(false);
  });

  it('polls for a while after a request even before the run appears', () => {
    expect(shouldPoll(fresh(), 1000, 2000)).toBe(true);
    expect(shouldPoll(fresh(), 1000, 1000 + 91_000)).toBe(false);
  });
});

describe('applyPollResult', () => {
  it('a GitHub error long after the request keeps the running run and keeps polling', () => {
    const after = applyPollResult(fresh([running]), { kind: 'ok', status: { runs: [], error: 'GitHub unreachable' } });
    expect(after.runs).toEqual([running]);
    expect(after.error).toBe('GitHub unreachable');
    expect(shouldPoll(after, 1000, 1000 + 99_000)).toBe(true);
  });

  it('a transient failure keeps state, then recovery clears the error and resets the count', () => {
    const failed = applyPollResult(fresh([running]), { kind: 'transient' });
    expect(failed.runs).toEqual([running]);
    expect(failed.failures).toBe(1);
    expect(shouldPoll(failed, 0, 1000)).toBe(true);

    const recovered = applyPollResult(failed, { kind: 'ok', status: { runs: [done], error: null } });
    expect(recovered).toEqual(fresh([done]));
    expect(shouldPoll(recovered, 0, 1000)).toBe(false);
  });

  it('gives up after a bounded run of failures', () => {
    let state = fresh([running]);
    for (let i = 0; i < MAX_CONSECUTIVE_FAILURES; i++) state = applyPollResult(state, { kind: 'transient' });
    expect(state.stopped).toBe(true);
    expect(state.error).toMatch(/Stopped checking.*Reload/);
    expect(shouldPoll(state, 0, 1000)).toBe(false);
  });

  it('an auth failure stops at once and is not masked as a restart', () => {
    const state = applyPollResult(fresh([running]), { kind: 'unauthorized' });
    expect(state.stopped).toBe(true);
    expect(state.error).toMatch(/site admin/);
  });
});

describe('classifyResponse', () => {
  it('separates restarts from lost authority', () => {
    expect(classifyResponse({ status: 502, ok: false, redirected: false })).toBe('transient');
    expect(classifyResponse({ status: 503, ok: false, redirected: false })).toBe('transient');
    expect(classifyResponse({ status: 404, ok: false, redirected: false })).toBe('unauthorized');
    expect(classifyResponse({ status: 200, ok: true, redirected: true })).toBe('unauthorized');
    expect(classifyResponse({ status: 200, ok: true, redirected: false })).toBe('ok');
  });
});

describe('expiryWarning', () => {
  const now = Date.parse('2026-10-08T00:00:00Z');

  it('is quiet when far away or unknown', () => {
    expect(expiryWarning(null, now)).toBeNull();
    expect(expiryWarning('2027-10-08T00:00:00Z', now)).toBeNull();
  });

  it('warns inside two weeks and after expiry', () => {
    expect(expiryWarning('2026-10-11T00:00:00Z', now)).toBe('The deploy token expires in 3 days.');
    expect(expiryWarning('2026-10-01T00:00:00Z', now)).toMatch(/has expired/);
  });
});

describe('applyPollResult with a partial failure', () => {
  it('keeps known automatic runs, takes fresh manual runs, shows the gap and keeps polling', () => {
    const autoRunning = { id: 9, status: 'in_progress', workflow: 'rails_auto', created_at: '2026-10-08T12:00:00Z' };
    const manualOld = {
      id: 1,
      status: 'completed',
      conclusion: 'success',
      workflow: 'rails',
      created_at: '2026-10-08T10:00:00Z',
    };
    const manualNew = {
      id: 2,
      status: 'completed',
      conclusion: 'success',
      workflow: 'rails',
      created_at: '2026-10-08T11:00:00Z',
    };
    const after = applyPollResult(fresh([autoRunning, manualOld]), {
      kind: 'ok',
      status: {
        runs: [manualNew, manualOld],
        error: null,
        partial_error: "Couldn't list automatic deploys: GitHub unreachable",
      },
    });
    expect(after.runs.map((run) => run.id)).toEqual([9, 2, 1]);
    expect(after.error).toMatch(/automatic deploys/);
    expect(after.stopped).toBe(false);
    expect(shouldPoll(after, 0, 1000)).toBe(true);
  });
});
