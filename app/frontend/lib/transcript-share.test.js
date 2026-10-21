import { describe, expect, it } from 'vitest';
import { expiryLine, transcriptLines, transcriptPlainText } from './transcript-share';

describe('transcriptPlainText', () => {
  it('writes one line per turn with its clock and speaker', () => {
    const turns = [
      { spk: 'speaker_0', start: 0, text: 'Hello  there ' },
      { spk: 'speaker_1', start: 65_000, text: 'Hi.' },
      { spk: null, start: 3_725_000, text: '(laughter)' },
    ];
    const names = { speaker_0: 'Daniel', speaker_1: 'Anna' };
    expect(transcriptPlainText(turns, names)).toBe(
      '[00:00] Daniel: Hello there\n[01:05] Anna: Hi.\n[1:02:05] Unattributed: (laughter)'
    );
  });

  it('leaves out empty turns and the clock of an untimed one', () => {
    const turns = [
      { spk: 'A', start: null, text: 'No time here' },
      { spk: 'B', start: 1000, text: '   ' },
    ];
    expect(transcriptPlainText(turns, {})).toBe('A: No time here');
  });
});

describe('transcriptLines', () => {
  it('reads the server text back into clock, speaker and words', () => {
    expect(transcriptLines('[00:03] Daniel: Hello: world\nloose line\n\n[1:02:03] Anna: Bye')).toEqual([
      { clock: '00:03', speaker: 'Daniel', text: 'Hello: world' },
      { clock: null, speaker: null, text: 'loose line' },
      { clock: '1:02:03', speaker: 'Anna', text: 'Bye' },
    ]);
  });

  it('reads a line with a speaker but no clock', () => {
    expect(transcriptLines('Daniel: hi')).toEqual([{ clock: null, speaker: 'Daniel', text: 'hi' }]);
  });
});

describe('expiryLine', () => {
  const now = Date.parse('2026-10-21T12:00:00Z');
  it('says when a link stops working', () => {
    expect(expiryLine(null, now)).toBe('Never expires');
    expect(expiryLine('2026-10-21T11:00:00Z', now)).toBe('Expired');
    expect(expiryLine('2026-10-21T12:30:00Z', now)).toBe('Expires in 30 minutes');
    expect(expiryLine('2026-10-22T12:00:00Z', now)).toBe('Expires in 24 hours');
    expect(expiryLine('2026-10-28T12:00:00Z', now)).toBe('Expires in 7 days');
  });
});
