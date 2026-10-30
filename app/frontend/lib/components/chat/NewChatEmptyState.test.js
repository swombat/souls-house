import { render, screen, within } from '@testing-library/svelte';
import NewChatEmptyState from './NewChatEmptyState.svelte';

test('offers active conversations in recency order', () => {
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
  expect(links.map((link) => link.textContent.trim())).toEqual(['First', 'Second', 'Third', 'Renamed today']);
  expect(links[0]).toHaveAttribute('href', '/accounts/account/chats/first');
  expect(nav).toHaveClass('md:hidden');
  expect(within(nav).getByText('Or pick an existing conversation:')).toBeInTheDocument();
  expect(screen.queryByText(/Select one or more residents/)).not.toBeInTheDocument();
});

test('omits the recent-conversation prompt when there are no active chats', () => {
  render(NewChatEmptyState, {
    accountId: 'account',
    chats: [{ id: 'archived', archived: true }],
  });
  expect(screen.queryByRole('navigation')).not.toBeInTheDocument();
});

test('shows a single conversation and a fallback for untitled chats', () => {
  render(NewChatEmptyState, {
    accountId: 'account',
    chats: [{ id: 'only', activity_at: '2026-09-25' }],
  });
  expect(screen.getAllByRole('link')).toHaveLength(1);
  expect(screen.getByRole('link')).toHaveTextContent('New Conversation');
});

test('spins a ring for each resident working in a recent conversation', () => {
  render(NewChatEmptyState, {
    accountId: 'account',
    chats: [
      {
        id: 'busy',
        title: 'Busy',
        activity_at: '2026-09-25',
        working_agent_ids: ['l', 'm'],
        participants_json: [
          { type: 'human', name: 'Daniel' },
          { type: 'agent', id: 'm', name: 'Mira', colour: 'violet' },
          { type: 'agent', id: 'l', name: 'Lume', colour: 'orange' },
        ],
      },
      { id: 'quiet', title: 'Quiet', activity_at: '2026-09-24', working_agent_ids: [] },
    ],
  });
  const spinners = screen.getAllByTestId('room-working');
  expect(spinners).toHaveLength(1);
  expect(spinners[0]).toHaveAttribute('title', 'Lume and Mira working');
  expect(screen.getAllByTestId('room-working-ring').map((ring) => ring.dataset.colour)).toEqual(['orange', 'violet']);
});

const many = Array.from({ length: 12 }, (_, i) => ({
  id: `c${i}`,
  title: `Chat ${i}`,
  activity_at: new Date(Date.UTC(2026, 9, 20 - i)).toISOString(),
}));

test('offers at most ten conversations even when the screen has room', () => {
  render(NewChatEmptyState, { accountId: 'account', chats: many });
  const links = screen.getAllByRole('link');
  expect(links).toHaveLength(10);
  expect(links[0]).toHaveTextContent('Chat 0');
  expect(links[9]).toHaveTextContent('Chat 9');
});

describe('fitting the screen', () => {
  let rectSpy, parentSpy;
  const rect = (bottom) => ({ top: bottom - 50, bottom, left: 0, right: 300, width: 300, height: 50, x: 0, y: bottom - 50 });

  beforeEach(() => {
    // jsdom has no layout: give the scroller a bottom edge at 300px and stack
    // each conversation 60px below the last, starting at 120px.
    rectSpy = vi.spyOn(Element.prototype, 'getBoundingClientRect').mockImplementation(function () {
      if (this.dataset?.testid === 'new-chat-empty-state') return rect(316);
      if (this.tagName === 'LI') return rect(120 + 60 * [...this.parentElement.children].indexOf(this));
      return rect(0);
    });
    parentSpy = vi.spyOn(HTMLElement.prototype, 'offsetParent', 'get').mockReturnValue(document.body);
  });

  afterEach(() => {
    rectSpy.mockRestore();
    parentSpy.mockRestore();
  });

  test('leaves out conversations that would be cut off at the bottom', async () => {
    render(NewChatEmptyState, { accountId: 'account', chats: many });
    // The scroller is 316px with 16px padding: bottoms at 120, 180, 240, 300 fit; 360 does not.
    await vi.waitFor(() => expect(screen.getAllByRole('link')).toHaveLength(4));
    expect(screen.getAllByRole('link').map((link) => link.textContent.trim())).toEqual([
      'Chat 0',
      'Chat 1',
      'Chat 2',
      'Chat 3',
    ]);
  });

  test('keeps the newest conversation even when nothing fits whole', async () => {
    rectSpy.mockImplementation(function () {
      if (this.dataset?.testid === 'new-chat-empty-state') return rect(50);
      if (this.tagName === 'LI') return rect(500);
      return rect(0);
    });
    render(NewChatEmptyState, { accountId: 'account', chats: many });
    await vi.waitFor(() => expect(screen.getAllByRole('link')).toHaveLength(1));
    expect(screen.getByRole('link')).toHaveTextContent('Chat 0');
  });
});
