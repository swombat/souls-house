import { render, screen, fireEvent } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import ChatSidebarHeader from './ChatSidebarHeader.svelte';

test('admin header has archive and deleted checkboxes, with deleted unchanged', async () => {
  const onToggleDeleted = vi.fn();
  render(ChatSidebarHeader, { canSeeDeleted: true, onToggleDeleted });
  expect(screen.queryByText('Resident-Only')).not.toBeInTheDocument();
  expect(screen.getAllByRole('checkbox')).toHaveLength(2);
  expect(screen.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();
  await fireEvent.click(screen.getByRole('checkbox', { name: 'Deleted' }));
  expect(onToggleDeleted).toHaveBeenCalledOnce();
});

test('member header has only the working archive filter', async () => {
  const onToggleArchived = vi.fn();
  render(ChatSidebarHeader, { onToggleArchived });
  expect(screen.getAllByRole('checkbox')).toHaveLength(1);
  expect(screen.queryByRole('checkbox', { name: 'Deleted' })).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('checkbox', { name: 'Archived' }));
  expect(onToggleArchived).toHaveBeenCalledOnce();
});
