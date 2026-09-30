export function number(value) {
  return value === null || value === undefined ? 'unknown' : new Intl.NumberFormat('en-US').format(value);
}

export function aggregateNumber(value, unknownRows) {
  if (value === null || value === undefined) return 'unknown';
  return unknownRows > 0 ? `${number(value)} known (+ ${unknownRows} unknown)` : number(value);
}

export function bytes(value) {
  if (value === null || value === undefined) return 'unknown';
  if (value < 1024) return `${value} B`;
  if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
  return `${(value / 1024 / 1024).toFixed(1)} MiB`;
}

export function aggregateBytes(value, unknownRows) {
  if (value === null || value === undefined) return 'unknown';
  return unknownRows > 0 ? `${bytes(value)} known (+ ${unknownRows} unknown)` : bytes(value);
}

export function duration(value) {
  if (value === null || value === undefined) return 'unknown';
  if (value < 1000) return `${value} ms`;
  if (value < 60_000) return `${(value / 1000).toFixed(1)} s`;
  if (value < 3_600_000) return `${(value / 60_000).toFixed(1)} min`;
  return `${(value / 3_600_000).toFixed(1)} h`;
}

export function timestamp(value) {
  if (!value) return 'unknown';
  return (
    new Intl.DateTimeFormat('en-GB', {
      timeZone: 'UTC',
      year: 'numeric',
      month: '2-digit',
      day: '2-digit',
      hour: '2-digit',
      minute: '2-digit',
      second: '2-digit',
      hour12: false,
    }).format(new Date(value)) + ' UTC'
  );
}

export function list(values) {
  return values?.length ? values.join(', ') : 'unknown';
}

export function booleanState(value) {
  if (value === true) return 'yes';
  if (value === false) return 'no';
  return 'unknown';
}

export function mapSummary(values) {
  const entries = Object.entries(values || {});
  return entries.length ? entries.map(([key, value]) => `${key}: ${value}`).join(' · ') : 'none';
}

export function telemetryClass(state) {
  if (state === 'complete')
    return 'border-green-300 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950 dark:text-green-300';
  if (state === 'unsupported')
    return 'border-red-300 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300';
  return 'border-amber-300 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300';
}

export function lifecycleClass(outcome) {
  if (outcome === 'resumed') return 'bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300';
  if (outcome === 'rolled' || outcome === 'fresh_fallback' || outcome === 'resume_timeout')
    return 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300';
  if (outcome === 'failed') return 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300';
  return 'bg-slate-100 text-slate-800 dark:bg-slate-900 dark:text-slate-300';
}
