// Sharing a recording's transcript: the plain text that "Copy transcript"
// puts on the clipboard, the token in a shared link, and how a link's
// expiry reads. Kept free of Svelte so they can be unit tested.
import { formatClock, turnSpeakerName } from '$lib/field-recordings';

export const SHARE_EXPIRIES = [
  { value: '1h', label: '1 hour' },
  { value: '1d', label: '1 day' },
  { value: '1w', label: '1 week' },
  { value: 'never', label: 'Never' },
];
export const DEFAULT_SHARE_EXPIRY = '1d';

// The turns as the page shows them, one per line: "[mm:ss] Name: words", the
// same shape the server keeps as the recording's plain text. A supplied turn
// keeps its own line breaks, and has a clock or a speaker only where the
// transcript gave one; a timed turn nobody is attributed to reads
// "Unattributed", as on the server.
export function transcriptPlainText(turns = [], names = {}) {
  return (turns || [])
    .map((turn) => {
      const supplied = turn.index != null;
      const text = supplied
        ? String(turn.text ?? '').trim()
        : String(turn.text ?? '')
            .replace(/\s+/g, ' ')
            .trim();
      if (!text) return null;
      const clock = turn.start != null ? `[${formatClock(turn.start)}] ` : '';
      const speaker = turn.spk || !supplied ? `${turnSpeakerName(turn, names)}: ` : '';
      return `${clock}${speaker}${text}`;
    })
    .filter(Boolean)
    .join('\n');
}

// The token from a shared link's fragment ("#sht_…"), or null.
export function shareTokenFromHash(hash = '') {
  const token = String(hash || '').replace(/^#/, '');
  return /^sht_[A-Za-z0-9_-]{43}$/.test(token) ? token : null;
}

// "Expires in 23 hours", "Expires in 6 days", "Never expires", "Expired".
export function expiryLine(expiresAt, now = Date.now()) {
  if (!expiresAt) return 'Never expires';
  const ms = new Date(expiresAt).getTime() - now;
  if (!(ms > 0)) return 'Expired';
  const minutes = Math.ceil(ms / 60000);
  if (minutes < 60) return `Expires in ${minutes} minute${minutes === 1 ? '' : 's'}`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `Expires in ${hours} hour${hours === 1 ? '' : 's'}`;
  const days = Math.round(hours / 24);
  return `Expires in ${days} days`;
}
