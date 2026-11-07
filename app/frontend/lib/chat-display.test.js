import { describe, expect, it } from 'vitest';
import { commitmentMarkLabel } from './chat-display';

describe('commitmentMarkLabel', () => {
  it('names the resident and the time', () => {
    const label = commitmentMarkLabel({ due_at: '2026-11-09T08:30:00Z', resident_name: 'Lume', count: 1 }, 'en-GB');
    expect(label).toMatch(/^Lume will come back here /);
    expect(label).toMatch(/Nov/);
    expect(label).not.toMatch(/waiting/);
  });

  it('says how many when more than one is waiting', () => {
    expect(commitmentMarkLabel({ due_at: '2026-11-09T08:30:00Z', resident_name: 'Mira', count: 3 }, 'en-GB')).toMatch(
      /\(3 waiting\)$/
    );
  });

  it('is empty without a commitment', () => {
    expect(commitmentMarkLabel(null)).toBe('');
    expect(commitmentMarkLabel({ due_at: 'nonsense' })).toBe('');
  });
});
