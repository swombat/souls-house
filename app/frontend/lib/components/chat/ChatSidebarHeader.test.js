import { render, screen, fireEvent } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import { tick } from 'svelte';
import ChatSidebarHeader from './ChatSidebarHeader.svelte';

async function openFilter() {
  await fireEvent.click(screen.getByTestId('chat-filter-trigger'));
  await tick();
}

test('admin filter has archived, deleted and hidden checkboxes, with deleted unchanged', async () => {
  const onToggleDeleted = vi.fn();
  render(ChatSidebarHeader, { canSeeDeleted: true, onToggleDeleted });
  await openFilter();
  expect(screen.queryByText('Resident-Only')).not.toBeInTheDocument();
  expect(screen.getAllByRole('checkbox')).toHaveLength(4);
  expect(screen.getByRole('checkbox', { name: /Human replied since/ })).not.toBeChecked();
  expect(screen.getByRole('checkbox', { name: 'Archived' })).not.toBeChecked();
  await fireEvent.click(screen.getByRole('checkbox', { name: 'Deleted' }));
  expect(onToggleDeleted).toHaveBeenCalledOnce();
});

test('member filter has archived and hidden but not deleted', async () => {
  const onToggleArchived = vi.fn();
  render(ChatSidebarHeader, { onToggleArchived });
  await openFilter();
  expect(screen.getAllByRole('checkbox')).toHaveLength(3);
  expect(screen.getByRole('checkbox', { name: /Human replied since/ })).not.toBeChecked();
  expect(screen.queryByRole('checkbox', { name: 'Deleted' })).not.toBeInTheDocument();
  await fireEvent.click(screen.getByRole('checkbox', { name: 'Archived' }));
  expect(onToggleArchived).toHaveBeenCalledOnce();
});
