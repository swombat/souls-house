import { describe, it, expect } from 'vitest';
import { deployLines } from './deployInfo.js';

const deployed = { sha: 'a'.repeat(40), short: 'aaaaaaa', dirty: false, booted_at: '2026-10-04T12:00:00Z' };
const master = { sha: 'b'.repeat(40), short: 'bbbbbbb', committed_at: '2026-10-04T14:24:30Z', message: 'Merge #150' };

describe('deployLines', () => {
  it('shows deployed and merged separately, with the gap', () => {
    const text = deployLines({ deployed, master, behind_by: 3 }).map((l) => l.text);
    expect(text[0]).toMatch(/^Deployed aaaaaaa · up /);
    expect(text[1]).toMatch(/^Master bbbbbbb · committed /);
    expect(text[2]).toBe('Live build is 3 commits behind master');
  });

  it('says up to date only when behind_by is exactly 0', () => {
    expect(deployLines({ deployed, master, behind_by: 0 }).at(-1).text).toBe('Live build is up to date with master');
    expect(deployLines({ deployed, master, behind_by: null })).toHaveLength(2);
  });

  it('never invents a deployed revision', () => {
    const text = deployLines({ deployed: null, master, behind_by: null }).map((l) => l.text);
    expect(text[0]).toBe('Deployed: unknown (no build revision)');
    expect(text.join(' ')).not.toMatch(/up to date|behind/);
  });

  it('marks uncommitted builds and reports GitHub failure as unknown', () => {
    const text = deployLines({ deployed: { ...deployed, dirty: true }, master: null, behind_by: null }).map(
      (l) => l.text
    );
    expect(text[0]).toContain('(uncommitted)');
    expect(text[1]).toBe('Master: unknown (GitHub unreachable)');
  });

  it('handles loading and failure', () => {
    expect(deployLines(null)[0].text).toBe('Loading deploy info…');
    expect(deployLines(null, { failed: true })[0].text).toBe('Deploy info unavailable');
  });

  it('adds the deploy alarm verdict when there is one', () => {
    const stuck = deployLines({
      deployed,
      master,
      behind_by: 3,
      alarm: { state: 'stuck', reason: 'Last automatic deploy failed.' },
    });
    expect(stuck.at(-1)).toEqual({
      text: 'Deploy alarm: production has stopped following master',
      title: 'Last automatic deploy failed.',
    });
    expect(deployLines({ deployed, master, behind_by: 0, alarm: { state: 'ok' } }).at(-1).text).toBe(
      'Live build is up to date with master'
    );
    expect(deployLines({ deployed, master, behind_by: null, alarm: { state: 'unknown', banner: false } })).toHaveLength(
      2
    );
  });
});
