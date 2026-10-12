// Wording and requests for a Telegram connection's sign-in and status on the
// integrations page. The two-step password goes through postLoginJson only:
// a plain fetch, never the Inertia router, so it never reaches page props or
// browser history.

function waitWords(seconds) {
  const n = Number(seconds);
  if (!Number.isFinite(n) || n <= 0) return 'Telegram asked us to wait before trying again.';
  return `Telegram asked us to wait ${n} ${n === 1 ? 'second' : 'seconds'}.`;
}

export function loginErrorMessage(login) {
  switch (login?.error) {
    case undefined:
    case null:
    case '':
      return null;
    case 'expired':
      return 'The code expired. Restart sign-in for a new one.';
    case 'password_invalid':
      return 'That password was not right. Try again.';
    case 'flood_wait':
      return waitWords(login.retry_after);
    case 'cancelled':
      return 'Sign-in was cancelled.';
    default:
      return 'Sign-in failed. Restart sign-in to try again.';
  }
}

export function passwordOutcomeMessage(result) {
  switch (result?.outcome) {
    case 'accepted':
      return { tone: 'ok', text: 'Password accepted. Finishing sign-in.' };
    case 'password_invalid':
      return { tone: 'error', text: 'That password was not right. Try again.' };
    case 'flood_wait':
      return { tone: 'error', text: waitWords(result.retry_after) };
    case 'not_configured':
      return {
        tone: 'error',
        text: 'The Telegram connector is not set up on this house, so the password was not sent.',
      };
    case 'failed':
      return { tone: 'error', text: 'Sign-in failed. Restart sign-in to try again.' };
    default:
      return { tone: 'error', text: result?.error || 'Something went wrong. Try again.' };
  }
}

export const availabilityMessages = {
  queued: 'Waiting for a place on the Telegram connector. Syncing starts when one is free.',
  busy: 'The Telegram connector is busy. New messages may arrive late.',
  backlogged: 'New messages are paused until the house catches up with the ones it has.',
  unavailable: 'Syncing is stopped for this account until the house can safely restart it. Chats already synced can still be read.',
};

export function availabilityMessage(availability) {
  const state = availability?.state;
  if (!state || state === 'ok') return null;
  return availabilityMessages[state] || 'Telegram syncing is not working normally.';
}

export function secondsUntil(iso, now = Date.now()) {
  const at = Date.parse(iso);
  if (Number.isNaN(at)) return 0;
  return Math.max(0, Math.ceil((at - now) / 1000));
}

export function formatCountdown(seconds) {
  const minutes = Math.floor(seconds / 60);
  return `${minutes}:${String(seconds % 60).padStart(2, '0')}`;
}

function csrfToken() {
  return document.querySelector('meta[name="csrf-token"]')?.getAttribute('content') || '';
}

// Returns { ok, status, body } and never throws for an HTTP error.
export async function postLoginJson(url, body = {}) {
  try {
    const response = await fetch(url, {
      method: 'POST',
      credentials: 'same-origin',
      cache: 'no-store',
      headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'X-CSRF-Token': csrfToken() },
      body: JSON.stringify(body),
    });
    let json = {};
    try {
      json = await response.json();
    } catch {
      json = {};
    }
    return { ok: response.ok, status: response.status, body: json };
  } catch {
    return { ok: false, status: 0, body: { error: 'Could not reach the house. Check the connection and try again.' } };
  }
}
