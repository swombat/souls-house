import { render, screen } from '@testing-library/svelte';
import HandoffReceipts from './HandoffReceipts.svelte';

test('renders nothing when the message handed off to no one', () => {
  const { container } = render(HandoffReceipts, { receipts: [] });
  expect(container.querySelector('[data-testid="handoff-receipts"]')).toBeNull();
});

test('shows each recipient and where the message has got to', () => {
  render(HandoffReceipts, {
    receipts: [
      { recipient_id: 'mira', recipient_name: 'Mira', state: 'queued', reason: null },
      { recipient_id: 'lume', recipient_name: 'Lume', state: 'delivered', reason: null },
    ],
  });
  const receipts = screen.getAllByTestId('handoff-receipt');
  expect(receipts.map((node) => node.textContent.trim())).toEqual(['to Mira · queued', 'to Lume · delivered']);
  expect(receipts[1]).toHaveAttribute('title', expect.stringMatching(/Whether to reply is theirs/));
});

test('a blocked receipt says why', () => {
  render(HandoffReceipts, {
    receipts: [{ recipient_id: 'mira', recipient_name: 'Mira', state: 'blocked', reason: 'loop_cap' }],
  });
  const receipt = screen.getByTestId('handoff-receipt');
  expect(receipt).toHaveTextContent('to Mira · blocked: loop_cap');
  expect(receipt).toHaveAttribute('data-state', 'blocked');
});
