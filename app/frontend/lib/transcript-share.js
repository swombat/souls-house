// Sharing a recording's transcript: the plain text that "Copy transcript"
// puts on the clipboard, the lines the shared page shows, and how a link's
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
// same shape the server keeps as the recording's plain text. A turn with no
// time (a supplied transcript without timings) has no clock.
export function transcriptPlainText(turns = [], names = {}) {
  return (turns || [])
    .map((turn) => {
      const text = String(turn.text ?? '')
        .replace(/\s+/g, ' ')
        .trim();
      if (!text) return null;
      const clock = turn.start != null ? `[${formatClock(turn.start)}] ` : '';
      return `${clock}${turnSpeakerName(turn, names)}: ${text}`;
    })
    .filter(Boolean)
    .join('\n');
}

const LINE = /^(?:\[(\d{1,2}(?::\d{2}){1,2})\]\s+)?([^:\n]{1,80}):\s(.*)$/;

// The shared page's lines, from the server's plain text. A line that doesn't
// read "[clock] Name: words" is kept whole as words with no speaker, so
// nothing in the transcript is ever dropped.
export function transcriptLines(text = '') {
  return String(text || '')
    .split('\n')
    .filter((line) => line.trim() !== '')
    .map((line) => {
      const match = line.match(LINE);
      if (!match) return { clock: null, speaker: null, text: line };
      return { clock: match[1] ?? null, speaker: match[2], text: match[3] };
    });
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
