// Pure helpers for the site-admin Deploy page.

export const POLL_AFTER_REQUEST_MS = 90_000;
export const MAX_CONSECUTIVE_FAILURES = 40; // ~5 minutes at 8s
export const STOPPED_MESSAGE = 'Stopped checking after repeated failures. Reload the page to check again.';

export function runLabel(run) {
  if (!run) return '';
  if (run.status !== 'completed') {
    return run.status === 'in_progress' ? '… running' : `… ${run.status || 'queued'}`;
  }
  // Superseded fails the GitHub job (#313) but isn't a crash: say what it was.
  if (run.workflow === 'rails_auto' && run.outcome === 'superseded') return '– master moved on, nothing deployed';
  // Deferred (#1096): a backup held a resident paused, so nothing switched.
  if (run.workflow === 'rails_auto' && run.outcome === 'deferred') return '– a backup held the switch, nothing deployed';
  // Automatic runs say what actually shipped; a successful run alone doesn't.
  if (run.conclusion === 'success' && run.workflow === 'rails_auto') {
    if (run.outcome === 'deployed') return '✓ deployed';
    if (run.outcome === 'superseded') return '– master moved on, nothing deployed';
    if (run.outcome === 'not_deployed') return '– not deployed';
    return '✓ finished (outcome unknown)';
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

// The row above the runs when master is ahead of what is live and its own
// automatic deploy isn't listed yet: what happens next, or why nothing will.
const NEXT_LABELS = {
  waiting_ci: '… waiting for CI, deploys when green',
  starting: '… CI green, deploy starting',
  ci_failed: '✗ CI failed, will not deploy automatically',
  ci_cancelled: '– CI cancelled, will not deploy automatically',
  ci_unknown: '? could not read CI, retrying',
};

export function nextLabel(next) {
  if (!next) return '';
  return NEXT_LABELS[next.state] || next.state || '';
}

// Still heading for a deploy on its own, or not known yet because GitHub
// didn't answer, so worth polling for.
export function nextPending(next) {
  return !!next && ['waiting_ci', 'starting', 'ci_unknown'].includes(next.state);
}

// The polling state machine. `state` is { runs, next, error, failures, stopped }.
// `result` is one of:
//   { kind: 'ok', status }      – a JSON status body from the server
//   { kind: 'transient' }       – network error or 5xx (e.g. Rails restarting)
//   { kind: 'unauthorized' }    – the session is no longer a site admin
// A transient failure, or a GitHub error reported in the body, keeps the last
// known runs (and next row), so a run that was in flight is still in flight
// and polling goes on.
export function applyPollResult(state, result) {
  if (result.kind === 'unauthorized') {
    return { ...state, stopped: true, error: 'Signed out or no longer a site admin. Reload the page.' };
  }
  if (result.kind === 'transient') {
    const failures = state.failures + 1;
    const stopped = failures >= MAX_CONSECUTIVE_FAILURES;
    return {
      ...state,
      failures,
      error: stopped ? STOPPED_MESSAGE : 'Waiting for the house to answer (it may be restarting)…',
      stopped,
    };
  }
  const status = result.status || {};
  if (status.error) {
    const failures = state.failures + 1;
    const stopped = failures >= MAX_CONSECUTIVE_FAILURES;
    return { ...state, failures, error: stopped ? `${status.error}. ${STOPPED_MESSAGE}` : status.error, stopped };
  }
  if (status.partial_error) {
    // Only the automatic listing failed: take the fresh manual runs, keep the
    // automatic runs we already knew about (one may still be in flight, which
    // keeps polling going), and say what is missing.
    const kept = (state.runs || []).filter((run) => run.workflow === 'rails_auto');
    const fresh = (status.runs || []).filter((run) => run.workflow !== 'rails_auto');
    const runs = [...fresh, ...kept].sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    return { runs, next: state.next ?? null, error: status.partial_error, failures: 0, stopped: false };
  }
  // next_unknown: the server couldn't read master this time; keep the row we had.
  const next = status.next_unknown ? (state.next ?? null) : (status.next ?? null);
  return { runs: status.runs || [], next, error: null, failures: 0, stopped: false };
}

export function shouldPoll(state, requestedAt, now) {
  if (state.stopped) return false;
  if (requestedAt && now - requestedAt < POLL_AFTER_REQUEST_MS) return true;
  return inFlight(state.runs) || nextPending(state.next);
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
