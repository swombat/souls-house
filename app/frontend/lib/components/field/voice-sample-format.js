// Shared wording and formatting for a voice's fingerprint samples.
export const STATES = {
  review: { label: 'Needs review', tone: 'bg-amber-100 text-amber-900 dark:bg-amber-900/40 dark:text-amber-100' },
  confirmed: {
    label: 'Confirmed',
    tone: 'bg-emerald-100 text-emerald-900 dark:bg-emerald-900/40 dark:text-emerald-100',
  },
  removed: { label: 'Removed', tone: 'bg-muted text-muted-foreground' },
  not_ready: { label: 'Not ready to play', tone: 'bg-muted text-muted-foreground' },
  preparing: { label: 'Preparing…', tone: 'bg-sky-100 text-sky-900 dark:bg-sky-900/40 dark:text-sky-100' },
};

export function seconds(ms) {
  const total = Math.round((ms || 0) / 1000);
  return `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`;
}

export function span(ms) {
  return `${(ms / 1000).toFixed(1)}s`;
}

export function spansTitle(sample) {
  return sample.segments?.length
    ? `Source spans: ${sample.segments.map(([from, to]) => `${span(from)}–${span(to)}`).join(', ')}`
    : 'Spans not recorded';
}

export function date(iso) {
  return new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}
