import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import ResidentMigration from './resident-migration.svelte';

const report = (overrides = {}) => ({
  ready: false,
  gates: [
    {
      name: 'Resident servers switched on',
      ok: false,
      refusal: "This house isn't creating resident servers right now",
    },
    { name: 'Stopped and can be copied', ok: true, refusal: null },
  ],
  limits: {
    compressed_bytes: 67108864,
    unpacked_bytes: 268435456,
    entries: 20000,
    archive_entries: 19996,
    archive_expanded_bytes: 412000000,
    archive_compressed_bytes: 104857600,
  },
  whole: null,
  roles: [],
  measure_error: null,
  facts: ['No live move until rollback after cutover is built (#426 slice 3C).'],
  ...overrides,
});

const resident = { id: 7, name: 'Synthetic', account_name: 'Test house' };

test('shows every gate, says it will refuse, and measures only when asked', async () => {
  render(ResidentMigration, { resident, report: report() });
  expect(screen.getByText('Resident servers switched on')).toBeVisible();
  expect(screen.getByText('Stopped and can be copied')).toBeVisible();
  expect(screen.getByText(/It will refuse now: This house isn't creating/)).toBeVisible();
  expect(screen.getByText('Not measured yet.')).toBeVisible();
  await fireEvent.click(screen.getByRole('button', { name: 'Measure sizes' }));
  expect(router.post).toHaveBeenCalledWith('/admin/agents/7/migration/measure', {}, { preserveScroll: true });
});

test('shows a role that would be refused, and moves only after confirming', async () => {
  const roles = [
    { role: 'identity', compressed_bytes: 1048576, unpacked_bytes: 2097152, entries: 12, fits: true, refusal: null },
    {
      role: 'work',
      compressed_bytes: 99 * 1048576,
      unpacked_bytes: 300 * 1048576,
      entries: 30,
      fits: false,
      refusal: 'The work home is larger than a resident server can be seeded with (256 MB unpacked)',
    },
  ];
  const whole = {
    entries: 30000,
    expanded_bytes: 1,
    compressed_bytes: 1,
    legacy_rows: 0,
    fits: false,
    refusal: 'Resident files exceed v1 limits',
  };
  render(ResidentMigration, { resident, report: report({ roles, whole }), measured: true });
  expect(screen.getByText(/The work home is larger/)).toBeVisible();
  expect(screen.getByTestId('migration-whole')).toHaveTextContent('Resident files exceed v1 limits');
  await fireEvent.click(screen.getByTestId('migration-move'));
  expect(router.post).not.toHaveBeenCalled();
  await fireEvent.click(screen.getByTestId('migration-confirm'));
  expect(router.post).toHaveBeenCalledWith('/admin/agents/7/migration', {}, expect.any(Object));
});
