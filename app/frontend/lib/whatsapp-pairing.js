// The owner's WhatsApp pairing on the integrations page: which code to show
// as codes rotate, and when the pairing has run out.

function issuedAt(qr) {
  const at = Date.parse(qr?.issued_at ?? '');
  if (!Number.isNaN(at)) return at;
  const expires = Date.parse(qr?.expires_at ?? '');
  return Number.isNaN(expires) ? -Infinity : expires;
}

// A code the server stops serving while it still has this long left was
// cleared (a restart, a status change), not expired: it is dropped. Nearer
// its expiry it is kept, so a small clock difference with the server still
// shows it as expired rather than vanishing.
export const CLEARED_MARGIN_MS = 10_000;

// The code to show after a poll. An older code never replaces a newer one
// (a slow reply can land after a faster, later one); a missing code keeps
// the last one, which then shows as expired.
export function newerQr(current, incoming, now = Date.now()) {
  if (!incoming?.code) {
    if (!current?.code) return null;
    return Date.parse(current.expires_at) - now > CLEARED_MARGIN_MS ? null : current;
  }
  if (!current?.code) return incoming;
  if (incoming.code === current.code) return issuedAt(incoming) >= issuedAt(current) ? incoming : current;
  return issuedAt(incoming) > issuedAt(current) ? incoming : current;
}

// WhatsApp sends a new code shortly before the last one expires; only after
// this long with nothing newer has pairing run out.
export const EXPIRY_GRACE_SECONDS = 5;

export function pairingPhase({ status, qr, secondsLeft, secondsSinceExpiry }) {
  if (status === 'connected') return 'connected';
  if (status === 'reauthorizing') return 'logged_out';
  if (status === 'error') return 'error';
  if (status !== 'pairing') return 'unavailable';
  if (!qr?.code) return 'waiting';
  if (secondsLeft > 0) return 'scan';
  return secondsSinceExpiry >= EXPIRY_GRACE_SECONDS ? 'expired' : 'rotating';
}
