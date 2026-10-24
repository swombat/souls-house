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

// Phone number pairing ("Link with phone number instead"): someone on the
// phone WhatsApp is on cannot scan a QR on that same screen, so a
// phone-sized or touch screen leads with the phone number; a desktop leads
// with the QR. Either way the owner can switch.
export const PHONE_FIRST_QUERY = '(max-width: 639px), (pointer: coarse)';

export function defaultPairingMethod(phoneFirst) {
  return phoneFirst ? 'phone' : 'qr';
}

// WhatsApp's code is 8 characters, entered as XXXX-XXXX.
export function formatPhoneCode(code) {
  const plain = String(code ?? '')
    .replace(/[^A-Za-z0-9]/g, '')
    .toUpperCase();
  return plain.length === 8 ? `${plain.slice(0, 4)}-${plain.slice(4)}` : plain;
}

// Where the phone pairing is, from the pairing endpoint's `phone` step,
// its `phone_code` and the seconds that code has left.
export function phonePairingPhase({ status, phone, phoneCode, secondsLeft }) {
  if (status !== 'pairing') return 'inactive';
  if (phoneCode?.code) return secondsLeft > 0 ? 'code' : 'expired';
  if (phone?.error === 'expired' || phone?.step === 'code') return 'expired';
  if (phone?.error) return 'failed';
  if (phone?.step === 'requested') return 'requesting';
  return 'number';
}

// A phone pairing underway keeps the phone flow on screen, whatever the
// screen size.
export function phonePairingUnderway(phone, phoneCode) {
  return Boolean(phoneCode?.code || phone?.step || phone?.error);
}

const PHONE_FAILURES = {
  phone_invalid: 'WhatsApp did not accept that number. Use the number WhatsApp is on, with + and the country code.',
  rate_limited: 'WhatsApp is not giving out codes for this number right now. Wait a few minutes, then restart pairing.',
  not_ready: 'WhatsApp did not answer in time. Try again, or restart pairing.',
};

export function phoneFailureMessage(reason) {
  return PHONE_FAILURES[reason] || 'WhatsApp could not make a code. Try again, or restart pairing.';
}
