import { describe, expect, it } from 'vitest';
import {
  activeWordIndex,
  allowanceLine,
  buildTurns,
  formatClock,
  formatDuration,
  guessSpeakers,
  parseNameMatch,
  preflightProblem,
  recordingStatusLine,
  speakerNames,
  timedWords,
  turnSpeakerName,
} from './field-recordings';

const w = (s, e, t, spk, k = 'w') => ({ s, e, t, k, spk });
const sp = (s, t = ' ') => ({ s, e: s, t, k: 's' });

describe('buildTurns', () => {
  it('joins consecutive words of one speaker with their spacing', () => {
    const turns = buildTurns([w(0, 300, 'Okay,', 'speaker_0'), sp(300), w(400, 700, 'right.', 'speaker_0')]);
    expect(turns).toHaveLength(1);
    expect(turns[0]).toMatchObject({ spk: 'speaker_0', start: 0, end: 700, text: 'Okay, right.' });
    expect(turns[0].parts.map((part) => part.i ?? null)).toEqual([0, null, 1]);
  });

  it('starts a new turn when the speaker changes', () => {
    const turns = buildTurns([w(0, 300, 'Hi', 'speaker_0'), sp(300), w(400, 700, 'Hello', 'speaker_1')]);
    expect(turns.map((turn) => [turn.spk, turn.text])).toEqual([
      ['speaker_0', 'Hi'],
      ['speaker_1', 'Hello'],
    ]);
  });

  it('breaks a turn at a gap over 1.5 s but not at exactly 1.5 s', () => {
    const turns = buildTurns([
      w(0, 1000, 'one', 'speaker_0'),
      sp(1000),
      w(2500, 2800, 'two', 'speaker_0'),
      sp(2800),
      w(4301, 4500, 'three', 'speaker_0'),
    ]);
    expect(turns.map((turn) => turn.text)).toEqual(['one two', 'three']);
  });

  it('keeps audio events in the turn and leaves unlabelled words unattributed', () => {
    const turns = buildTurns([
      w(0, 200, 'So', 'speaker_0'),
      sp(200),
      w(300, 900, '(laughter)', 'speaker_0', 'a'),
      w(1000, 1200, 'mm', null),
    ]);
    expect(turns.map((turn) => turn.text)).toEqual(['So (laughter)', 'mm']);
    const names = speakerNames([{ label: 'speaker_0', name: null, default_name: 'Speaker 1' }]);
    expect(turns.map((turn) => turnSpeakerName(turn, names))).toEqual(['Speaker 1', 'Unattributed']);
  });

  it('drops leading spacing and copes with nothing', () => {
    expect(buildTurns([sp(0), w(10, 20, 'x', 'a')])[0].text).toBe('x');
    expect(buildTurns([])).toEqual([]);
    expect(buildTurns(null)).toEqual([]);
  });

  it('finds the word playing', () => {
    const list = timedWords(buildTurns([w(0, 300, 'a', 's0'), sp(300), w(400, 700, 'b', 's0')]));
    expect(activeWordIndex(list, 100)).toBe(0);
    expect(activeWordIndex(list, 350)).toBe(-1);
    expect(activeWordIndex(list, 500)).toBe(1);
    expect(activeWordIndex(list, 900)).toBe(-1);
  });
});

describe('recording wording', () => {
  it('formats durations and clocks', () => {
    expect(formatDuration(12_000_000)).toBe('3 h 20 m');
    expect(formatDuration(7_500_000)).toBe('2 h 05 m');
    expect(formatDuration(72_000_000)).toBe('20 h');
    expect(formatDuration(45 * 60_000)).toBe('45 m');
    expect(formatDuration(40_000)).toBe('40 s');
    expect(formatClock(65_000)).toBe('01:05');
    expect(formatClock(3_723_000)).toBe('1:02:03');
  });

  it('describes the allowance, with what is still transcribing', () => {
    const allowance = { limit_ms: 72_000_000, used_ms: 12_000_000, pending_ms: 0, window_days: 7 };
    expect(allowanceLine(allowance)).toBe('3 h 20 m of 20 h used in the last 7 days');
    expect(allowanceLine({ ...allowance, pending_ms: 4_200_000 })).toBe(
      '3 h 20 m of 20 h used in the last 7 days (1 h 10 m still transcribing)'
    );
  });

  it('warns before uploading something longer than what is left', () => {
    const allowance = { limit_ms: 6_000_000, used_ms: 0 };
    expect(preflightProblem(7_500_000, allowance)).toBe('This recording is 2 h 05 m; 1 h 40 m left this week.');
    expect(preflightProblem(60_000, allowance)).toBe('');
    expect(preflightProblem(Infinity, allowance)).toBe('');
  });

  it('guesses speakers from a title naming two people', () => {
    expect(guessSpeakers('Venue planning with Priya and Tomás')).toEqual({ count: 3, reason: '2 named + you' });
    expect(guessSpeakers('Garden notes')).toBeNull();
  });

  it('says the status in plain words', () => {
    expect(recordingStatusLine({ status: 'probing' })).toBe('Checking the recording…');
    expect(recordingStatusLine({ status: 'queued' })).toBe('Transcribing…');
    expect(recordingStatusLine({ status: 'ready', speaker_names: ['Sam', 'Speaker 2'] })).toBe('Sam, Speaker 2');
    expect(recordingStatusLine({ status: 'rejected', failure_reason: 'No audio.' })).toBe('No audio.');
  });

  it('reads the same-name question', () => {
    expect(parseNameMatch('{"voice_id":"v1","name":"Priya","last_named_in":"Venue"}')).toEqual({
      voice_id: 'v1',
      name: 'Priya',
      last_named_in: 'Venue',
    });
    expect(parseNameMatch('nope')).toBeNull();
  });
});
