import { render, screen } from '@testing-library/svelte';
import { describe, it, expect } from 'vitest';
import DeployAlarmBanner from './DeployAlarmBanner.svelte';
import { alarmBanner, followsMaster } from './deployAlarm.js';

const base = {
  deployed_short: 'fcb643c',
  master_short: '1e35e62',
  deploys_path: '/admin/deploys',
  runbook_url: 'https://example.test/runbook#recovery',
  last_run_url: 'https://example.test/run/1',
};

const stuck = {
  ...base,
  state: 'stuck',
  banner: true,
  behind_by: 3,
  since: '2026-10-09T22:12:00Z',
  reason: 'Last automatic deploy (7257c15) failed at “Deploy”.',
};

describe('DeployAlarmBanner', () => {
  it('stuck: red, says where production is, since when, and why, with links', () => {
    render(DeployAlarmBanner, { alarm: stuck });
    const banner = screen.getByTestId('deploy-alarm-banner');
    expect(banner).toHaveAttribute('data-tone', 'alert');
    expect(banner).toHaveAttribute('role', 'alert');
    expect(banner.textContent).toContain(
      'Production is on fcb643c, 3 commits behind master since 22:12Z. Last automatic deploy (7257c15) failed'
    );
    expect(screen.getByRole('link', { name: 'Deploys' })).toHaveAttribute('href', '/admin/deploys');
    expect(screen.getByRole('link', { name: 'Recovery runbook' })).toHaveAttribute('href', base.runbook_url);
  });

  it('unknown for long enough: neutral, never "fine"', () => {
    render(DeployAlarmBanner, {
      alarm: {
        ...base,
        state: 'unknown',
        banner: true,
        since: '2026-10-09T21:40:00Z',
        reason: 'GitHub didn’t say where master is.',
      },
    });
    const banner = screen.getByTestId('deploy-alarm-banner');
    expect(banner).toHaveAttribute('data-tone', 'neutral');
    expect(banner.textContent).toContain("Can't tell whether production follows master since 21:40Z.");
    expect(banner.textContent).not.toMatch(/up to date|fine/i);
  });

  it('unknown not yet for long: nothing', () => {
    render(DeployAlarmBanner, { alarm: { ...base, state: 'unknown', banner: false, since: '2026-10-09T21:40:00Z' } });
    expect(screen.queryByTestId('deploy-alarm-banner')).toBeNull();
  });

  it('stale check: neutral line naming the silence', () => {
    render(DeployAlarmBanner, {
      alarm: { ...base, state: 'unknown', banner: true, stale: true, since: '2026-10-09T20:00:00Z' },
    });
    expect(screen.getByTestId('deploy-alarm-banner').textContent).toContain(
      "the deploy alarm hasn't checked since 20:00Z"
    );
  });

  it('ok and missing: nothing', () => {
    render(DeployAlarmBanner, { alarm: { ...base, state: 'ok', banner: false } });
    render(DeployAlarmBanner, { alarm: null });
    expect(screen.queryByTestId('deploy-alarm-banner')).toBeNull();
  });
});

describe('alarm words', () => {
  it('one commit is singular', () => {
    expect(alarmBanner({ ...stuck, behind_by: 1 }).text).toContain('1 commit behind master');
  });

  it('dashboard tile says yes / no since / unknown', () => {
    expect(followsMaster({ state: 'ok' }).value).toBe('yes');
    expect(followsMaster(stuck).value).toBe('no since 22:12Z');
    expect(followsMaster({ state: 'unknown' }).value).toBe('unknown');
    expect(followsMaster(null).value).toBe('unknown');
    expect(followsMaster({ state: 'ok', stale: true }).value).toBe('unknown');
  });
});
