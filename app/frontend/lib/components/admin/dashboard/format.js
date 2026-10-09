// Formatting and small maths for the site dashboard. Kept free of Svelte so
// it can be tested directly.

export function formatCount(value) {
  if (value === null || value === undefined) return '—';
  return new Intl.NumberFormat('en-GB').format(value);
}

export function formatUsd(value, { precise = false } = {}) {
  if (value === null || value === undefined) return '—';
  const digits = precise || Math.abs(value) < 10 ? 2 : 0;
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency: 'USD',
    minimumFractionDigits: digits,
    maximumFractionDigits: digits,
  }).format(value);
}

export function formatPercent(value, digits = 1) {
  if (value === null || value === undefined) return '—';
  return `${(value * 100).toFixed(digits)}%`;
}

const UNITS = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];

export function formatBytes(bytes) {
  if (bytes === null || bytes === undefined) return '—';
  if (bytes === 0) return '0 B';
  const exponent = Math.min(Math.floor(Math.log(Math.abs(bytes)) / Math.log(1024)), UNITS.length - 1);
  const value = bytes / 1024 ** exponent;
  return `${value >= 100 || exponent === 0 ? value.toFixed(0) : value.toFixed(1)} ${UNITS[exponent]}`;
}

// "+3 this week" style delta. Returns null when there is nothing to say.
export function weeklyDelta(added) {
  if (!added) return null;
  return `+${formatCount(added)} this week`;
}

// Change between two periods as a signed label and a direction.
export function periodChange(value, previous) {
  if (previous === null || previous === undefined) return null;
  const diff = value - previous;
  if (diff === 0) return { label: 'same as last week', direction: 'flat' };
  return {
    label: `${diff > 0 ? '+' : '−'}${formatCount(Math.abs(diff))} vs last week`,
    direction: diff > 0 ? 'up' : 'down',
  };
}

// Sum of each day across series: [{a:[1,2]},{b:[3,4]}] -> [4,6]
export function stackTotals(seriesByKey, keys) {
  const length = keys.length ? (seriesByKey[keys[0]] || []).length : 0;
  return Array.from({ length }, (_, i) => keys.reduce((sum, key) => sum + ((seriesByKey[key] || [])[i] || 0), 0));
}

// Scale values (nulls allowed) into SVG points within width x height.
// Nulls break the line: the result is a list of segments.
export function linePoints(values, width, height, { min = 0, max = null, pad = 2 } = {}) {
  const present = values.filter((value) => value !== null && value !== undefined);
  if (!present.length) return [];
  const top = max ?? Math.max(...present);
  const bottom = Math.min(min, ...present);
  const span = top - bottom || 1;
  const step = values.length > 1 ? (width - pad * 2) / (values.length - 1) : 0;
  const segments = [];
  let current = [];
  values.forEach((value, i) => {
    if (value === null || value === undefined) {
      if (current.length) segments.push(current);
      current = [];
      return;
    }
    const x = pad + i * step;
    const y = height - pad - ((value - bottom) / span) * (height - pad * 2);
    current.push([Math.round(x * 10) / 10, Math.round(y * 10) / 10]);
  });
  if (current.length) segments.push(current);
  return segments;
}

export function shortDate(iso) {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' });
}

export function lastValue(values) {
  for (let i = values.length - 1; i >= 0; i -= 1) {
    if (values[i] !== null && values[i] !== undefined) return values[i];
  }
  return null;
}

export function shortDateTime(iso) {
  if (!iso) return '?';
  return new Date(iso).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}

// "measured hourly" stops being true the moment readings go missing or old;
// say so next to the total instead of letting it pass as complete.
export function coverageNote(coverage) {
  if (!coverage || !coverage.expected) return null;
  const parts = [];
  if (coverage.missing) parts.push(`${coverage.missing} of ${coverage.expected} not measured`);
  if (coverage.stale) parts.push(`${coverage.stale} stale since ${shortDateTime(coverage.oldest_sampled_at)}`);
  return parts.length ? `Partial: ${parts.join(', ')}` : null;
}
