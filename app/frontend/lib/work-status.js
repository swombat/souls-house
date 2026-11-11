export const WORK_STATUSES = [
  { state: 'working', label: 'Working', colour: 'text-blue-600 dark:text-blue-400', icon: 'Hammer' },
  { state: 'ready_for_review', label: 'Ready for review', colour: 'text-green-600 dark:text-green-400', icon: 'Eye' },
  { state: 'needs_input', label: 'Needs your input', colour: 'text-yellow-600 dark:text-yellow-400', icon: 'Play' },
  { state: 'blocked', label: 'Blocked', colour: 'text-red-600 dark:text-red-400', icon: 'Stop' },
  { state: 'completed', label: 'Completed', colour: 'text-green-600 dark:text-green-400', icon: 'CheckCircle' },
  { state: 'idle', label: 'Idle', colour: 'text-muted-foreground', icon: 'Pause' },
];

export function workStatusInfo(state) {
  return WORK_STATUSES.find((entry) => entry.state === state) || null;
}

export function workStatusDate(value) {
  const date = new Date(value);
  return value && !Number.isNaN(date.valueOf()) ? date.toLocaleString() : '';
}

export function workStatusDescription(status) {
  const info = workStatusInfo(status?.state);
  if (!info) return 'Work status not declared';
  return [
    `${info.label} (reported)`,
    status.reason,
    status.since ? `Since ${workStatusDate(status.since)}` : null,
    status.human_replied_since
      ? `Human replied since: ${workStatusDate(status.human_replied_since)}; status not yet updated`
      : null,
    'Separate from live runtime activity and unanswered requests.',
  ]
    .filter(Boolean)
    .join(' · ');
}
