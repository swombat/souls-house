import { describe, expect, it } from 'vitest';
import { stepPath, availableShare } from './hetzner-availability.js';

const start = Date.parse('2026-11-13T00:00:00Z');
const end = Date.parse('2026-11-13T01:00:00Z');

describe('stepPath', () => {
  it('steps between checks and holds the last value for one interval', () => {
    const d = stepPath(
      [
        ['2026-11-13T00:00:00Z', 0],
        ['2026-11-13T00:05:00Z', 1],
      ],
      start,
      end,
      120,
      20
    );
    expect(d).toBe('M0.0,17 L10.0,17 L10.0,3 L20.0,3');
  });

  it('breaks the line where a check failed or checks went missing', () => {
    const d = stepPath(
      [
        ['2026-11-13T00:00:00Z', 1],
        ['2026-11-13T00:05:00Z', null],
        ['2026-11-13T00:10:00Z', 0],
        ['2026-11-13T00:40:00Z', 0],
      ],
      start,
      end,
      120,
      20
    );
    expect(d.match(/M/g)).toHaveLength(3);
  });

  it('draws nothing without checks', () => {
    expect(stepPath([], start, end, 120, 20)).toBe('');
  });
});

describe('availableShare', () => {
  it('ignores checks that could not be made', () => {
    expect(
      availableShare([
        ['a', 1],
        ['b', 0],
        ['c', null],
      ])
    ).toBe(0.5);
    expect(availableShare([['a', null]])).toBeNull();
  });
});
