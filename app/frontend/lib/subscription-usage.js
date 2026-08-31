const WEEK_MS = 7 * 24 * 60 * 60 * 1000;

export function displayUsageWindows(usage, provider, modelId = '') {
  const windows = Array.isArray(usage?.windows) ? usage.windows : [];
  const model = modelId.toLowerCase();

  if (provider === 'gemini') {
    const gemini = windows.filter((window) => windowLabel(window).startsWith('gemini '));
    return compactWindows([findWindow(gemini, '5-hour', '5-hour'), findWindow(gemini, 'weekly', 'Weekly')]);
  }

  if (provider === 'anthropic') {
    return compactWindows([
      findExactWindow(windows, 'session', '5-hour'),
      findExactWindow(windows, 'weekly', 'Weekly'),
    ]);
  }

  if (provider === 'xai') {
    return compactWindows([{ ...windows[0], displayLabel: 'Weekly' }]);
  }

  if (provider === 'openai') {
    if (model.includes('codex-spark')) {
      const spark = windows.filter((window) => windowLabel(window).includes('codex-spark'));
      return compactWindows([findWindow(spark, 'session', '5-hour'), findWindow(spark, 'weekly', 'Weekly')]);
    }

    const weekly =
      windows.find((window) => String(window.id || '').toLowerCase() === 'session') ||
      windows.find((window) => windowLabel(window) === 'session');
    return compactWindows([{ ...weekly, displayLabel: 'Weekly' }]);
  }

  return windows.map((window) => ({ ...window, displayLabel: window.label || 'Usage' }));
}

export function predictedWeeklyUsage(windows, now = Date.now()) {
  const weekly = windows.find((window) => window.displayLabel === 'Weekly');
  const resetAt = Date.parse(weekly?.resets_at);
  if (!weekly || !Number.isFinite(resetAt) || resetAt <= now) return null;

  const remaining = clampPercent(weekly.remaining_percent);
  const used = 100 - remaining;
  const elapsed = WEEK_MS - (resetAt - now);
  if (elapsed <= 0) return used === 0 ? 0 : null;

  return Math.round((used * WEEK_MS) / elapsed);
}

export function weeklyRemainingPercent(usage, provider, modelId = '') {
  const weekly = displayUsageWindows(usage, provider, modelId).find((window) => window.displayLabel === 'Weekly');
  return weekly ? clampPercent(weekly.remaining_percent) : null;
}

export function predictionTone(prediction) {
  if (prediction > 100) return 'danger';
  if (prediction >= 75) return 'warning';
  return 'muted';
}

export function usageLine(window, now = Date.now(), locale) {
  const remaining = clampPercent(window.remaining_percent);
  const reset = resetDescription(window.resets_at, now, locale);
  return `${window.displayLabel}: ${formatPercent(remaining)}% left${reset ? `, ${reset}` : ''}`;
}

export function resetDescription(value, now = Date.now(), locale) {
  const resetAt = Date.parse(value);
  if (!Number.isFinite(resetAt)) return '';

  const totalMinutes = Math.ceil((resetAt - now) / 60_000);
  if (totalMinutes <= 0) return 'reset pending';
  if (totalMinutes < 24 * 60) {
    const hours = Math.floor(totalMinutes / 60);
    const minutes = totalMinutes % 60;
    return `resets in ${hours ? `${hours}h` : ''}${minutes ? `${minutes}m` : ''}`;
  }

  const date = new Intl.DateTimeFormat(locale, { day: 'numeric', month: 'short' }).format(resetAt);
  const time = new Intl.DateTimeFormat(locale, { hour: 'numeric', minute: '2-digit' }).format(resetAt);
  return `resets ${date}, ${time}`;
}

function findWindow(windows, text, displayLabel) {
  const window = windows.find((candidate) => windowLabel(candidate).includes(text));
  return window && { ...window, displayLabel };
}

function findExactWindow(windows, label, displayLabel) {
  const window = windows.find((candidate) => windowLabel(candidate) === label);
  return window && { ...window, displayLabel };
}

function compactWindows(windows) {
  return windows.filter((window) => window?.resets_at);
}

function windowLabel(window) {
  return String(window?.label || '').toLowerCase();
}

function clampPercent(value) {
  return Math.max(0, Math.min(100, Number(value) || 0));
}

function formatPercent(value) {
  return value.toFixed(value % 1 === 0 ? 0 : 1);
}
