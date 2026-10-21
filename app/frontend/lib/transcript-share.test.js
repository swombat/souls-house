import { describe, expect, it } from 'vitest';
import { expiryLine, shareTokenFromHash, transcriptPlainText } from './transcript-share';

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

  it('leaves out empty turns', () => {
    expect(transcriptPlainText([{ spk: 'B', start: 1000, text: '   ' }], {})).toBe('');
  });

  it('keeps a supplied turn as written: its line breaks, and no speaker it was not given', () => {
    const turns = [
      { spk: 'A', start: null, index: 0, text: 'Agenda:\n- one\n- two' },
      { spk: null, start: 5000, index: 1, text: 'We agreed on the following: Ship tomorrow.' },
      { spk: null, start: null, index: 2, text: 'A paragraph with nobody named.' },
    ];
    expect(transcriptPlainText(turns, { A: 'Anna' })).toBe(
      'Anna: Agenda:\n- one\n- two\n[00:05] We agreed on the following: Ship tomorrow.\nA paragraph with nobody named.'
    );
  });
});

describe('shareTokenFromHash', () => {
  it('takes only a token-shaped fragment', () => {
    const token = `sht_${'a'.repeat(43)}`;
    expect(shareTokenFromHash(`#${token}`)).toBe(token);
    expect(shareTokenFromHash('')).toBeNull();
    expect(shareTokenFromHash('#sht_short')).toBeNull();
    expect(shareTokenFromHash(`#${token}x`)).toBeNull();
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
