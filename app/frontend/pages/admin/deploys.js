// Pure helpers for the site-admin Deploy page.

const POLL_AFTER_REQUEST_MS = 90_000;

export function runLabel(run) {
  if (!run) return '';
  if (run.status !== 'completed') {
    return run.status === 'in_progress' ? '… running' : `… ${run.status || 'queued'}`;
  }
  switch (run.conclusion) {
    case 'success':
      return '✓ success';
    case 'failure':
      return '✗ failed';
    case 'cancelled':
      return '– cancelled';
    case 'skipped':
      return '– skipped';
    default:
      return run.conclusion || 'completed';
  }
}

export function shouldPoll(runs, requestedAt, now) {
  if (requestedAt && now - requestedAt < POLL_AFTER_REQUEST_MS) return true;
  return (runs || []).some((run) => run.status !== 'completed');
}

// A warning line when the token expires within two weeks, or already has.
export function expiryWarning(expiresAt, now = Date.now()) {
  if (!expiresAt) return null;
  const at = Date.parse(expiresAt);
  if (Number.isNaN(at)) return null;
  if (at <= now) return 'The deploy token has expired. Make a new one and update the credentials.';
  const days = Math.floor((at - now) / 86_400_000);
  if (days < 14)
    return `The deploy token expires in ${days === 0 ? 'less than a day' : `${days} day${days === 1 ? '' : 's'}`}.`;
  return null;
}
