// Pure helpers for the site-admin Deploy page.

export const POLL_AFTER_REQUEST_MS = 90_000;
export const MAX_CONSECUTIVE_FAILURES = 40; // ~5 minutes at 8s

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

export function inFlight(runs) {
  return (runs || []).some((run) => run.status !== 'completed');
}

// The polling state machine. `state` is { runs, error, failures, stopped }.
// `result` is one of:
//   { kind: 'ok', status }      – a JSON status body from the server
//   { kind: 'transient' }       – network error or 5xx (e.g. Rails restarting)
//   { kind: 'unauthorized' }    – the session is no longer a site admin
// A transient failure, or a GitHub error reported in the body, keeps the last
// known runs, so a run that was in flight is still in flight and polling goes on.
export function applyPollResult(state, result) {
  if (result.kind === 'unauthorized') {
    return { ...state, stopped: true, error: 'Signed out or no longer a site admin. Reload the page.' };
  }
  if (result.kind === 'transient') {
    const failures = state.failures + 1;
    return {
      ...state,
      failures,
      error: 'Waiting for the house to answer (it may be restarting)…',
      stopped: failures >= MAX_CONSECUTIVE_FAILURES,
    };
  }
  const status = result.status || {};
  if (status.error) {
    const failures = state.failures + 1;
    return { ...state, failures, error: status.error, stopped: failures >= MAX_CONSECUTIVE_FAILURES };
  }
  return { runs: status.runs || [], error: null, failures: 0, stopped: false };
}

export function shouldPoll(state, requestedAt, now) {
  if (state.stopped) return false;
  if (requestedAt && now - requestedAt < POLL_AFTER_REQUEST_MS) return true;
  return inFlight(state.runs);
}

// Classifies a fetch Response for applyPollResult (body read separately).
export function classifyResponse(response) {
  if (response.status === 401 || response.status === 403 || response.status === 404) return 'unauthorized';
  if (response.redirected) return 'unauthorized';
  if (!response.ok) return 'transient';
  return 'ok';
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
