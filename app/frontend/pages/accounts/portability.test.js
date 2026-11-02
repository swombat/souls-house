import { render, screen } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import Portability from './portability.svelte';

vi.mock('@inertiajs/svelte', async (original) => ({
  ...(await original()),
  router: { post: vi.fn(), reload: vi.fn(), visit: vi.fn() },
}));

const base = {
  account: { id: 'home', name: 'Home' },
  limits: { compressed: 16 * 1024 ** 3, expanded: 16 * 1024 ** 3, entries: 50000, entry: 2 * 1024 ** 3 },
  never_travels: ['provider credentials'],
  conversations_warning: "Other people's messages travel with this archive.",
  export_url: '/accounts/home/exports',
  import_url: '/accounts/home/imports',
};

test('warns before export which residents would be skipped, and shows the limits', () => {
  render(Portability, {
    ...base,
    residents: [{ name: 'Mira', exportable: false, reason: 'V1 requires an inactive, paused hosted resident' }],
  });
  const warning = screen.getByTestId('export-skipped-warning');
  expect(warning.textContent).toContain('Mira: V1 requires an inactive, paused hosted resident');
  expect(warning.textContent).toContain('partial export');
  expect(screen.getByText(/16 GiB archive/)).toBeTruthy();
  expect(screen.getByText(/2 GiB per file/)).toBeTruthy();
  expect(screen.getByText(/Other people's messages travel/)).toBeTruthy();
});

test('an account that is not empty is told why it cannot import', () => {
  render(Portability, {
    ...base,
    destination_refusal: 'This account already has residents. Import into a new, empty account.',
  });
  expect(screen.getByTestId('import-refusal').textContent).toContain('already has residents');
  expect(screen.queryByTestId('import-file')).toBeNull();
});

test('a previewed import shows its hash, a same-house warning and needs the confirmation box', () => {
  const preview = {
    account_name: 'Old house',
    created_at: '2026-11-02T08:00:00Z',
    partial: true,
    sha256: 'a'.repeat(64),
    same_installation: true,
    residents: [
      { key: 'r1', name: 'Lume', status: 'included' },
      { key: 'r2', name: 'Mira', status: 'skipped', reason: 'running' },
    ],
    field: { files: 1, recordings: 2, songs: 0, notes: 3, tags: 1 },
    rooms: ['Main'],
    rhythms: 1,
    conversations: 0,
    services: [{ provider: 'dropbox', label: 'Daniel' }],
  };
  render(Portability, {
    ...base,
    imports: [{ id: 'i1', status: 'previewed', preview, created_at: '2026-11-02T08:00:00Z' }],
  });
  const shown = screen.getByTestId('import-preview').textContent;
  expect(shown).toContain('a'.repeat(64));
  expect(shown).toContain('second, separate copy');
  expect(shown).toContain('Mira is not in the archive: running');
  expect(shown).toContain('Reconnect afterwards: dropbox (Daniel)');
  expect(screen.getByRole('button', { name: 'Import' }).disabled).toBe(true);
});
