import { expect, test } from 'vitest';
import { activityMaximum, activityHeight } from './activity-chart';

test('uses the largest stacked bar across every group and bucket', () => {
  const groups = [
    { bars: [{ segments: [{ value: 2 }, { value: 4 }] }] },
    { bars: [{ segments: [{ value: 9 }] }, { segments: [{ value: 3 }] }] },
  ];
  expect(activityMaximum(groups)).toBe(9);
  expect(activityHeight(3, activityMaximum(groups))).toBeCloseTo(100 / 3);
});

test('empty charts and zero buckets do not invent activity', () => {
  expect(activityMaximum([])).toBe(1);
  expect(activityMaximum([{ bars: [{ segments: [{ value: 0 }] }] }])).toBe(1);
  expect(activityHeight(0, 1, 4)).toBe(0);
  expect(activityHeight(1, 100, 4)).toBe(4);
});
