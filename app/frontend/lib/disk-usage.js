export function diskSize(bytes) {
  if (bytes == null) return '—';
  if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(0)} KiB`;
  if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MiB`;
  return `${(bytes / 1024 ** 3).toFixed(1)} GiB`;
}

// The card's disk use (Agents::HomeStorage). A size, when any walk has
// finished; otherwise why not, so "not measured yet" never looks like
// "can't be measured".
export function diskNote(storage) {
  if (!storage?.status) return null;
  if (storage.bytes != null) return storage.status === 'measured' ? null : '(stale)';
  if (storage.status === 'too_slow') return '(too large to measure)';
  return '(unavailable)';
}

export function diskTitle(storage) {
  const what = 'Persistent disk usage across identity, Chaos, repo, work and state volumes.';
  const when = (iso) => new Date(iso).toLocaleString();
  if (!storage?.status) return `${what} Awaiting background measurement, at most hourly.`;
  const measured = storage.measured_at ? ` Measured ${when(storage.measured_at)}.` : '';
  if (storage.status === 'measured') return `${what}${measured}`;
  const why =
    storage.status === 'too_slow'
      ? 'the walk took longer than its time limit'
      : storage.reason === 'runner_too_old'
        ? "its server's runner can't measure this yet; it updates itself"
        : 'the measurement failed';
  return `${what}${measured} Last tried ${when(storage.attempted_at)}: ${why}.`;
}
