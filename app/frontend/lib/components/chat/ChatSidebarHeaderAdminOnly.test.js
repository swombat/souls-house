import { fireEvent, render, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import ChatSidebarHeader from './ChatSidebarHeader.svelte';

const base = {
  accountId: 'acc',
  canSeeDeleted: true,
  onCreate: () => {},
  onToggleArchived: () => {},
  onToggleDeleted: () => {},
};

async function openFilter() {
  await fireEvent.click(screen.getByTestId('chat-filter-trigger'));
  await tick();
}

test('the Deleted toggle is red only when it is there because the viewer is a site admin', async () => {
  const { unmount } = render(ChatSidebarHeader, { ...base, deletedIsAdminOnly: true });
  await openFilter();
  const label = screen.getByText('Deleted').closest('label');
  expect(label.className).toContain('text-red-600');
  expect(label).toHaveAttribute('title', 'Site admins only');
  unmount();
  render(ChatSidebarHeader, { ...base, deletedIsAdminOnly: false });
  await openFilter();
  const memberLabel = screen.getByText('Deleted').closest('label');
  expect(memberLabel.className).not.toContain('text-red-600');
  expect(memberLabel.className).not.toContain('text-red');
});
