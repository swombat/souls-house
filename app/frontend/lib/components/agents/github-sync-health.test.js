import { render, screen } from '@testing-library/svelte';
import SyncHealth from './github-sync-health.svelte';

test.each(['unknown', 'stale', 'blocked', 'busy', 'failed', 'needs_attention'])(
  '%s never claims successful sync',
  (state) => {
    render(SyncHealth, { health: { state, reason_code: 'not_recorded' } });
    expect(screen.queryByRole('heading', { name: 'Last sync check succeeded' })).not.toBeInTheDocument();
    expect(screen.getByText('Not yet confirmed')).toBeVisible();
  }
);

test('confirmed sync shows timestamp and age, without claiming all hosts are current', () => {
  render(SyncHealth, {
    health: {
      state: 'ok',
      reason_code: 'synced',
      checked_at: '2026-10-06T10:00:00Z',
      last_success_at: '2026-10-06T08:00:00Z',
      last_success_age_seconds: 7200,
    },
  });
  expect(screen.getByText('2 hours ago (reported age)')).toBeVisible();
  expect(screen.getByText(/not live proof that every host is up to date/)).toBeVisible();
});

test.each(['pushed', 'failed'])('rescue %s is separate from branch sync', (rescueStatus) => {
  render(SyncHealth, {
    health: {
      state: 'needs_attention',
      reason_code: 'merge_conflict',
      last_success_at: '2026-10-05T10:00:00Z',
      last_success_age_seconds: 86400,
      rescue_status: rescueStatus,
      rescue_ref: 'rescue/example-host/20261006T100000000000Z-abcdef012345',
    },
  });
  expect(screen.getByText(/Rescue is not a successful sync/)).toBeVisible();
  expect(screen.getByText('rescue/example-host/20261006T100000000000Z-abcdef012345')).toBeVisible();
  expect(screen.getByText('1 day ago (reported age)')).toBeVisible();
  expect(screen.queryByRole('heading', { name: 'Last sync check succeeded' })).not.toBeInTheDocument();
});

test('even inconsistent ok plus rescue data cannot claim branch sync success', () => {
  render(SyncHealth, { health: { state: 'ok', reason_code: 'synced', rescue_status: 'pushed' } });
  expect(screen.getByRole('heading')).toHaveTextContent('Sync needs attention');
  expect(screen.queryByText(/branch was synchronized/)).not.toBeInTheDocument();
});

test('unknown runner codes or raw errors are not exposed', () => {
  render(SyncHealth, {
    health: { state: 'unexpected', reason_code: 'PRIVATE_RAW_OUTPUT', error: 'PRIVATE_ERROR' },
  });
  expect(screen.getByRole('heading')).toHaveTextContent('Sync not confirmed');
  expect(screen.queryByText(/PRIVATE/)).not.toBeInTheDocument();
});
