import { describe, expect, it } from 'vitest';
import { runLabel, shouldPoll, expiryWarning } from './deploys.js';

describe('runLabel', () => {
  it('labels in-flight and finished runs', () => {
    expect(runLabel({ status: 'queued' })).toBe('… queued');
    expect(runLabel({ status: 'in_progress' })).toBe('… running');
    expect(runLabel({ status: 'completed', conclusion: 'success' })).toBe('✓ success');
    expect(runLabel({ status: 'completed', conclusion: 'failure' })).toBe('✗ failed');
  });
});

describe('shouldPoll', () => {
  it('polls while a run is unfinished', () => {
    expect(shouldPoll([{ status: 'in_progress' }], 0, 1000)).toBe(true);
    expect(shouldPoll([{ status: 'completed' }], 0, 1000)).toBe(false);
  });

  it('polls for a while after a request even before the run appears', () => {
    expect(shouldPoll([], 1000, 2000)).toBe(true);
    expect(shouldPoll([], 1000, 1000 + 91_000)).toBe(false);
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
