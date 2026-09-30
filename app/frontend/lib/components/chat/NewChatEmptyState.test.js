import { render, screen, within } from '@testing-library/svelte';
import NewChatEmptyState from './NewChatEmptyState.svelte';

test('offers the latest three active conversations in recency order', () => {
  render(NewChatEmptyState, {
    accountId: 'account',
    chats: [
      { id: 'old', title: 'Renamed today', activity_at: '2026-09-01', updated_at: '2026-09-30' },
      { id: 'second', title: 'Second', activity_at: '2026-09-23' },
      { id: 'archived', title: 'Archived', archived: true, activity_at: '2026-09-26' },
      { id: 'first', title: 'First', activity_at: '2026-09-24' },
      { id: 'deleted', title: 'Deleted', discarded: true, activity_at: '2026-09-26' },
      { id: 'third', title: 'Third', activity_at: '2026-09-22' },
    ],
  });
  const nav = screen.getByRole('navigation', { name: 'Recent conversations' });
  const links = within(nav).getAllByRole('link');
  expect(links.map((link) => link.textContent.trim())).toEqual(['First', 'Second', 'Third']);
  expect(links[0]).toHaveAttribute('href', '/accounts/account/chats/first');
  expect(nav).toHaveClass('md:hidden');
});

test('omits the recent-conversation prompt when there are no active chats', () => {
  render(NewChatEmptyState, {
    accountId: 'account',
    chats: [{ id: 'archived', archived: true }],
  });
  expect(screen.queryByRole('navigation')).not.toBeInTheDocument();
});

test('shows fewer than three conversations and a fallback for untitled chats', () => {
  render(NewChatEmptyState, {
    accountId: 'account',
    chats: [{ id: 'only', activity_at: '2026-09-25' }],
  });
  expect(screen.getAllByRole('link')).toHaveLength(1);
  expect(screen.getByRole('link')).toHaveTextContent('New Conversation');
});
