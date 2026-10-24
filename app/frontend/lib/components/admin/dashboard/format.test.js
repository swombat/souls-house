import { describe, it, expect } from 'vitest';
import { formatBytes, formatUsd, periodChange, stackTotals, linePoints, lastValue, weeklyDelta } from './format.js';

describe('dashboard formatting', () => {
  it('formats bytes in binary units', () => {
    expect(formatBytes(0)).toBe('0 B');
    expect(formatBytes(1536)).toBe('1.5 KB');
    expect(formatBytes(5 * 1024 ** 3)).toBe('5.0 GB');
    expect(formatBytes(null)).toBe('—');
  });

  it('keeps cents only for small dollar amounts', () => {
    expect(formatUsd(3.456)).toBe('$3.46');
    expect(formatUsd(1234.5)).toBe('$1,235');
  });

  it('describes week-on-week change', () => {
    expect(periodChange(5, 3)).toEqual({ label: '+2 vs last week', direction: 'up' });
    expect(periodChange(3, 5).direction).toBe('down');
    expect(periodChange(4, 4).direction).toBe('flat');
    expect(periodChange(4, null)).toBeNull();
    expect(weeklyDelta(0)).toBeNull();
  });

  it('stacks series by day', () => {
    expect(stackTotals({ a: [1, 2], b: [3, 4] }, ['a', 'b'])).toEqual([4, 6]);
  });

  it('breaks lines at missing values', () => {
    const segments = linePoints([1, null, 3, 4], 100, 10, { pad: 0 });
    expect(segments).toHaveLength(2);
    expect(segments[0]).toHaveLength(1);
    expect(segments[1]).toHaveLength(2);
    expect(linePoints([null, null], 100, 10)).toEqual([]);
  });

  it('finds the last present value', () => {
    expect(lastValue([1, 2, null])).toBe(2);
    expect(lastValue([null])).toBeNull();
  });
});
