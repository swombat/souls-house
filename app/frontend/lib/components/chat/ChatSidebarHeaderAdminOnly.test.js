import { render, screen } from '@testing-library/svelte';
import ChatSidebarHeader from './ChatSidebarHeader.svelte';

const base = {
  accountId: 'acc',
  canSeeDeleted: true,
  onCreate: () => {},
  onToggleArchived: () => {},
  onToggleDeleted: () => {},
};

test('the Deleted toggle is red only when it is there because the viewer is a site admin', () => {
  const { unmount } = render(ChatSidebarHeader, { ...base, deletedIsAdminOnly: true });
  const label = screen.getByText('Deleted').closest('label');
  expect(label.className).toContain('text-red-600');
  expect(label).toHaveAttribute('title', 'Site admins only');
  unmount();
  render(ChatSidebarHeader, { ...base, deletedIsAdminOnly: false });
  const memberLabel = screen.getByText('Deleted').closest('label');
  expect(memberLabel.className).not.toContain('text-red-600');
  expect(memberLabel.className).toContain('text-muted-foreground');
});
