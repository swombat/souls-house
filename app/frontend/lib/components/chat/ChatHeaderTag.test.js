import { fireEvent, render, screen, within } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import { writable } from 'svelte/store';
import { page } from '@inertiajs/svelte';
import ChatHeader from './ChatHeader.svelte';
import ConversationCostDrawer from './ConversationCostDrawer.svelte';

const tag = { id: 'tag-one', label: 'Research', icon: 'MagnifyingGlass', colour: 'teal' };

vi.mock('@inertiajs/svelte', async () => {
  const { writable } = await import('svelte/store');
  return {
    page: writable({
      props: { visual_tags: [{ id: 'tag-one', label: 'Research', icon: 'MagnifyingGlass', colour: 'teal' }] },
    }),
    router: { patch: vi.fn(), post: vi.fn(), delete: vi.fn() },
  };
});
vi.mock('$lib/cable', () => ({ reloadProps: vi.fn(), subscribeToModel: vi.fn(() => vi.fn()) }));

const chat = { id: 'c1', title: 'Mobile tag button', manual_responses: true, visual_tag: null };
const account = { id: 'acc' };
const costBreakdown = {
  row_count: 2,
  totals: { uncached_input_tokens: 1150800 },
  estimated_cost: {
    amount_usd: 3.5,
    interaction_count: 2,
    pricing_as_of: '2026-11-01',
    subscription_estimate_usd: 17.2,
    subscription_interaction_count: 1,
  },
};

test('the header puts a tag button above the conversation menu and no cost line', async () => {
  render(ChatHeader, { chat, account, contextTokens: 42000 });
  const controls = screen.getByTestId('chat-header-controls');
  const buttons = within(controls).getAllByRole('button');
  expect(buttons[0]).toHaveAccessibleName('Change visual tag: No tag');
  expect(buttons[1]).toHaveAccessibleName('Conversation actions');
  // The untagged button is findable here, not the sidebar's barely-there outline.
  expect(buttons[0].className).not.toContain('text-muted-foreground/20');
  expect(screen.queryByText(/Context:/)).toBeNull();
  expect(screen.queryByText(/cache read/)).toBeNull();

  await fireEvent.click(buttons[0]);
  expect(await screen.findByRole('menuitem', { name: 'Research' })).toBeInTheDocument();
});

test('the View costs panel carries context and both dollar estimates', () => {
  render(ConversationCostDrawer, { open: true, breakdown: costBreakdown, contextTokens: 42000 });
  const summary = screen.getByTestId('cost-summary');
  expect(summary).toHaveTextContent('Context');
  expect(summary).toHaveTextContent('42');
  expect(summary).toHaveTextContent('≈$3.50');
  expect(within(summary).getByText('≈$17.20')).toHaveClass('line-through');
});

const visualTags = [tag];
const waiting = { due_at: '2026-11-17T08:00:00Z', resident_name: 'Lume', count: 1 };

test('a waiting commitment puts the grey clock beside the header tag, as in the sidebar', () => {
  page.set({ props: { visual_tags: visualTags, chats: [{ id: 'c1', next_commitment: waiting }] } });
  render(ChatHeader, { chat: { ...chat, visual_tag: tag }, account });
  const mark = within(screen.getByTestId('chat-header-tag')).getByTestId('commitment-mark');
  expect(mark).toHaveAttribute('data-placement', 'behind-tag');
  expect(mark.getAttribute('aria-label')).toMatch(/^Lume will come back here/);
  expect(mark.className).toContain('text-muted-foreground/40');
});

test('the sidebar row is the live value: a delivered commitment takes the clock away', () => {
  page.set({ props: { visual_tags: visualTags, chats: [{ id: 'c1', next_commitment: null }] } });
  render(ChatHeader, { chat: { ...chat, next_commitment: waiting }, account });
  expect(screen.queryByTestId('commitment-mark')).toBeNull();
});

test('a conversation outside the list falls back to its own next_commitment', () => {
  page.set({ props: { visual_tags: visualTags, chats: [] } });
  render(ChatHeader, { chat: { ...chat, next_commitment: waiting }, account });
  expect(screen.getByTestId('commitment-mark')).toHaveAttribute('data-placement', 'in-place');
});
