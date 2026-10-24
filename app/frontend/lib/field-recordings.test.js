import { describe, expect, it } from 'vitest';
import {
  groupSpeakers,
  automaticParts,
  speakerKeys,
  activeWordIndex,
  allowanceLine,
  buildTurns,
  formatClock,
  formatDuration,
  guessSpeakers,
  parseNameMatch,
  speakerQueryMatches,
  preflightProblem,
  recordingStatusLine,
  speakerNames,
  lineAddress,
  suppliedTurns,
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

  it('shows no limit, and never warns, when the account is unlimited', () => {
    const allowance = {
      limit_ms: 360_000_000_000,
      used_ms: 12_000_000,
      pending_ms: 0,
      window_days: 7,
      unlimited: true,
    };
    expect(allowanceLine(allowance)).toBe('3 h 20 m used in the last 7 days (no weekly limit)');
    expect(preflightProblem(400 * 3_600_000, allowance)).toBe('');
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

describe('suppliedTurns', () => {
  it('makes one untimed part per turn, keeping a start only where one was given', () => {
    const turns = suppliedTurns([
      { spk: null, s: null, t: 'Source: x.mp3' },
      { spk: 'Anna', s: 21000, t: 'How am I feeling?' },
      { spk: 'Daniel', t: 'Mm-hmm.' },
      { spk: 'Daniel', s: 5, t: '' },
    ]);
    expect(turns.map((turn) => [turn.spk, turn.start, turn.text])).toEqual([
      [null, null, 'Source: x.mp3'],
      ['Anna', 21000, 'How am I feeling?'],
      ['Daniel', null, 'Mm-hmm.'],
    ]);
    expect(turns[1].parts).toEqual([{ k: 'w', t: 'How am I feeling?', s: 21000, i: null, whole: true }]);
    expect(turnSpeakerName(turns[0], {})).toBe('Unattributed');
  });

  it("keeps each turn's position in the stored list, skipping none", () => {
    const turns = suppliedTurns([
      { spk: 'A', t: '' },
      { spk: 'B', t: 'Hello' },
    ]);
    expect(turns[0].index).toBe(1);
    expect(lineAddress(turns[0])).toEqual({ index: 1 });
  });

  it('copes with nothing', () => {
    expect(suppliedTurns(null)).toEqual([]);
  });
});

describe('lineAddress', () => {
  it('names a timed line by its first and last word', () => {
    const turns = buildTurns([
      w(0, 300, 'Hi', 'speaker_0'),
      sp(300),
      w(400, 700, 'Dad.', 'speaker_0'),
      w(5000, 5300, 'Yes', 'speaker_1'),
    ]);
    expect(lineAddress(turns[0])).toEqual({ first: 0, last: 1 });
    expect(lineAddress(turns[1])).toEqual({ first: 2, last: 2 });
  });
});

describe('speakerNames', () => {
  it('treats any label as a plain key, "__proto__" included', () => {
    const names = speakerNames([{ label: '__proto__', name: 'Odd label' }]);
    expect(turnSpeakerName({ spk: '__proto__' }, names)).toBe('Odd label');
    expect(turnSpeakerName({ spk: 'toString' }, names)).toBe('toString');
  });
});

describe('one voice heard as two speakers', () => {
  const speakers = [
    {
      id: 'a',
      label: 'speaker_0',
      position: 0,
      voice_id: 'v1',
      name: 'Ioan',
      talk_ms: 1000,
      clip_start_ms: 0,
      clip_end_ms: 900,
    },
    { id: 'b', label: 'speaker_1', position: 1, voice_id: null, name: 'Speaker 2', talk_ms: 500 },
    {
      id: 'c',
      label: 'speaker_2',
      position: 2,
      voice_id: 'v1',
      name: 'Ioan',
      talk_ms: 3000,
      clip_start_ms: 5000,
      clip_end_ms: 8000,
    },
    { id: 'd', label: 'speaker_3', position: 3, voice_id: null, name: 'Speaker 4', talk_ms: 200 },
  ];

  it('groups by the linked voice, never by name, in order of appearance', () => {
    const groups = groupSpeakers(speakers);
    expect(groups.map((group) => group.parts.map((part) => part.id))).toEqual([['a', 'c'], ['b'], ['d']]);
    expect(groups[0].speaker.id).toBe('c');
    expect(groups[0].speaker.talk_ms).toBe(4000);
    const twins = groupSpeakers([
      { id: 'x', label: 'x', position: 0, voice_id: null, name: 'Speaker 1' },
      { id: 'y', label: 'y', position: 1, voice_id: null, name: 'Speaker 1' },
    ]);
    expect(twins).toHaveLength(2);
  });

  it('talk time is unknown when any part is unknown', () => {
    const groups = groupSpeakers([
      { id: 'a', label: 'A', position: 0, voice_id: 'v1', talk_ms: null },
      { id: 'b', label: 'B', position: 1, voice_id: 'v1', talk_ms: null },
    ]);
    expect(groups[0].speaker.talk_ms).toBeNull();
  });

  it('a merged card keeps its automatic parts whichever part stands for it', () => {
    const human = {
      id: 'h',
      label: 'H',
      position: 0,
      voice_id: 'v1',
      named: true,
      auto_named: null,
      talk_ms: 9000,
      clip_start_ms: 0,
      clip_end_ms: 9000,
    };
    const automatic = {
      id: 'm',
      label: 'M',
      position: 1,
      voice_id: 'v1',
      named: true,
      auto_named: { confidence: 84 },
      talk_ms: 1000,
      clip_start_ms: 0,
      clip_end_ms: 1000,
    };

    const humanFirst = groupSpeakers([human, automatic])[0];
    expect(humanFirst.speaker.id).toBe('h');
    expect(humanFirst.speaker.auto_named).toBeNull();
    expect(automaticParts(humanFirst.parts).map((part) => part.id)).toEqual(['m']);

    const automaticFirst = groupSpeakers([
      { ...automatic, talk_ms: 9000, clip_end_ms: 9000 },
      { ...human, talk_ms: 1000, clip_end_ms: 1000 },
    ])[0];
    expect(automaticFirst.speaker.id).toBe('m');
    expect(automaticParts(automaticFirst.parts).map((part) => part.id)).toEqual(['m']);

    expect(automaticParts([{ ...automatic, named: false }])).toEqual([]);
    expect(automaticParts(undefined)).toEqual([]);
  });

  it('joins consecutive turns of one voice, not of different people', () => {
    const words = [
      w(0, 300, 'Hello', 'speaker_0'),
      sp(300),
      w(400, 700, 'again.', 'speaker_2'),
      w(800, 900, 'Hi.', 'speaker_1'),
    ];
    expect(buildTurns(words).length).toBe(3);
    const turns = buildTurns(words, speakerKeys(speakers));
    expect(turns.map((turn) => turn.text)).toEqual(['Hello again.', 'Hi.']);
  });
});

describe('speakerQueryMatches', () => {
  it('matches everything on an empty query', () => {
    expect(speakerQueryMatches('Anna', '')).toBe(true);
    expect(speakerQueryMatches('Anna', '   ')).toBe(true);
  });

  it('matches a substring regardless of case and accents', () => {
    expect(speakerQueryMatches('José Martín', 'mart')).toBe(true);
    expect(speakerQueryMatches('José Martín', 'JOSE')).toBe(true);
    expect(speakerQueryMatches('Anna', 'bob')).toBe(false);
  });
});
