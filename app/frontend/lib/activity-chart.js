// One scale across all groups, including stacked series and sub-day buckets.
export function activityMaximum(groups) {
  return Math.max(
    1,
    ...groups.flatMap((group) => group.bars.map((bar) => bar.segments.reduce((sum, segment) => sum + segment.value, 0)))
  );
}

export function activityHeight(value, maximum, minimum = 0) {
  return value > 0 ? Math.max(minimum, (value / maximum) * 100) : 0;
}
