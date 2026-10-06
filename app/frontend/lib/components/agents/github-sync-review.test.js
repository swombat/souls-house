import { render, screen } from '@testing-library/svelte';
import SyncReview from './github-sync-review.svelte';

test('an empty auto-commit policy does not promise to save edits', () => {
  render(SyncReview, { request: { sync_strategy: 'standard', sync_auto_commit_paths: [] } });
  expect(screen.getByText(/None — committed changes only/)).toBeVisible();
  expect(screen.getByText(/Uncommitted edits are not automatically saved/)).toBeVisible();
});

test('shows every reviewed policy and protection threshold as text', () => {
  render(SyncReview, {
    request: {
      sync_strategy: 'standard',
      sync_auto_commit_paths: ['journals', 'notes/<synthetic>.md'],
      sync_append_only_paths: ['journals'],
      sync_allow_destructive_paths: ['notes/<synthetic>.md'],
      sync_protected_paths: ['journals', 'notes/<synthetic>.md'],
      sync_shrink_minimum_ratio: 0.5,
    },
  });
  expect(screen.getByText(/shrink below 50%/)).toBeVisible();
  expect(screen.getByText(/always refuse rewriting or truncation/)).toBeVisible();
  expect(screen.getByText(/blocks keep their internal order, repeated lines and blanks/)).toBeVisible();
  expect(screen.getByText(/remote published block first, then the local block/)).toBeVisible();
  expect(screen.getByText(/Chronological order is not guaranteed/)).toBeVisible();
  expect(screen.queryByText(/concatenated in UTF-8 byte order/)).not.toBeInTheDocument();
  expect(screen.getAllByText('notes/<synthetic>.md')).toHaveLength(3);
  expect(screen.queryByRole('textbox')).not.toBeInTheDocument();
});

test('existing sync does not imply standard protections or enrollment', () => {
  render(SyncReview, { request: { sync_strategy: 'existing' } });
  expect(screen.getByText('Keep existing sync')).toBeVisible();
  expect(screen.getByText(/Existing residents are not enrolled/)).toBeVisible();
  expect(screen.queryByText('Eligible auto-commit paths')).not.toBeInTheDocument();
});
