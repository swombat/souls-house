import { render, screen, fireEvent } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import ChatSidebarHeader from './ChatSidebarHeader.svelte';

test('admin header has only the Deleted checkbox, which still works', async () => {
  const onToggleDeleted = vi.fn();
  render(ChatSidebarHeader, { canSeeDeleted: true, onToggleDeleted });
  expect(screen.queryByText('Resident-Only')).not.toBeInTheDocument();
  expect(screen.getAllByRole('checkbox')).toHaveLength(1);
  await fireEvent.click(screen.getByRole('checkbox', { name: 'Deleted' }));
  expect(onToggleDeleted).toHaveBeenCalledOnce();
});

test('member header has no filter checkboxes', () => {
  render(ChatSidebarHeader);
  expect(screen.queryByRole('checkbox')).not.toBeInTheDocument();
});
