// Recordings in the Field: pure helpers shared by the Field index and the
// transcript page. Kept free of Svelte so they can be unit tested.

export const TURN_GAP_MS = 1500;
export const UNATTRIBUTED = 'Unattributed';

// Words come from the server as {s, e, t, k, spk}: start and end in ms, the
// text, the kind ('w' word, 's' spacing, 'a' audio event) and the speaker
// label. A turn is consecutive words/events with the same speaker and gaps of
// at most 1.5 s; spacing between two words of one turn joins them. Every
// word/event gets `i`, its position among the timed words.
export function buildTurns(words = []) {
  const turns = [];
  let current = null;
  let spacing = null;
  let index = 0;

  for (const word of words || []) {
    if (!word) continue;
    if (word.k === 's') {
      if (current) spacing = (spacing ?? '') + (word.t ?? '');
      continue;
    }
    const part = { ...word, spk: word.spk || null, i: index++ };
    const end = part.e ?? part.s;
    if (current && current.spk === part.spk && part.s - current.end <= TURN_GAP_MS) {
      current.parts.push({ k: 's', t: spacing || ' ' });
      current.parts.push(part);
      current.end = Math.max(current.end, end);
    } else {
      current = { spk: part.spk, start: part.s, end, parts: [part] };
      turns.push(current);
    }
    spacing = null;
  }

  return turns.map((turn) => ({ ...turn, text: turn.parts.map((part) => part.t).join('') }));
}

// The timed words across all turns, in order, for finding the one playing.
export function timedWords(turns) {
  return turns.flatMap((turn) => turn.parts.filter((part) => part.k !== 's'));
}

// The `i` of the word playing at `ms`, or -1. `list` is sorted by start.
export function activeWordIndex(list, ms) {
  if (ms == null || !list?.length) return -1;
  let low = 0;
  let high = list.length - 1;
  let found = -1;
  while (low <= high) {
    const mid = (low + high) >> 1;
    if (list[mid].s <= ms) {
      found = mid;
      low = mid + 1;
    } else {
      high = mid - 1;
    }
  }
  if (found < 0) return -1;
  const word = list[found];
  return ms < (word.e ?? word.s) ? word.i : -1;
}

export function speakerNames(speakers = []) {
  const names = {};
  for (const speaker of speakers || []) names[speaker.label] = speaker.name || speaker.default_name || speaker.label;
  return names;
}

export function turnSpeakerName(turn, names) {
  if (!turn.spk) return UNATTRIBUTED;
  return names[turn.spk] || turn.spk;
}

// 00:00, or 1:02:03 past the hour.
export function formatClock(ms) {
  const total = Math.max(0, Math.floor((ms || 0) / 1000));
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const seconds = total % 60;
  const pad = (n) => String(n).padStart(2, '0');
  return hours ? `${hours}:${pad(minutes)}:${pad(seconds)}` : `${pad(minutes)}:${pad(seconds)}`;
}

// "3 h 20 m", "2 h 05 m", "20 h", "45 m", "40 s".
export function formatDuration(ms) {
  if (ms == null) return '';
  const value = Math.max(0, ms);
  if (value > 0 && value < 60000) return `${Math.round(value / 1000)} s`;
  const totalMinutes = Math.floor(value / 60000);
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  if (!hours) return `${minutes} m`;
  if (!minutes) return `${hours} h`;
  return `${hours} h ${String(minutes).padStart(2, '0')} m`;
}

export function allowanceLine(allowance) {
  if (!allowance) return '';
  const days = allowance.window_days || 7;
  const used = formatDuration(allowance.used_ms || 0);
  if (allowance.unlimited) {
    let open = `${used} used in the last ${days} days (no weekly limit)`;
    if ((allowance.pending_ms || 0) > 0) open += `, ${formatDuration(allowance.pending_ms)} still transcribing`;
    return open;
  }
  const limit = formatDuration(allowance.limit_ms || 0);
  let line = `${used} of ${limit} used in the last ${days} days`;
  if ((allowance.pending_ms || 0) > 0) line += ` (${formatDuration(allowance.pending_ms)} still transcribing)`;
  return line;
}

export function remainingMs(allowance) {
  if (!allowance || allowance.unlimited) return null;
  return Math.max(0, (allowance.limit_ms || 0) - (allowance.used_ms || 0));
}

// Advisory only: the server's probe decides.
export function preflightProblem(durationMs, allowance) {
  const left = remainingMs(allowance);
  if (durationMs == null || !Number.isFinite(durationMs) || left == null || durationMs <= left) return '';
  return `This recording is ${formatDuration(durationMs)}; ${formatDuration(left)} left this week.`;
}

// "Venue planning with Priya and Tomás" → 3: two named, plus you. A hint only.
export function guessSpeakers(title) {
  if (!title || !/(\w+) and (\w+)/i.test(title)) return null;
  return { count: 3, reason: '2 named + you' };
}

export function recordingStatusLine(item) {
  switch (item?.status) {
    case 'probing':
      return 'Checking the recording…';
    case 'queued':
    case 'transcribing':
      return 'Transcribing…';
    case 'ready':
      return item.speaker_names?.length ? item.speaker_names.join(', ') : 'Ready';
    case 'rejected':
      return item.failure_reason || "This recording couldn't be used.";
    case 'failed':
      return item.failure_reason || "The transcription didn't work.";
    default:
      return '';
  }
}

export function recordingsTabPath(accountId, recordingId = null) {
  const base = `/accounts/${accountId}/field?tab=recordings`;
  return recordingId ? `${base}&item=${encodeURIComponent(`recording-${recordingId}`)}` : base;
}

// The server asks "same Priya?" with errors.name_match as a JSON string.
export function parseNameMatch(value) {
  if (!value) return null;
  if (typeof value === 'object') return value;
  try {
    return JSON.parse(value);
  } catch {
    return null;
  }
}
