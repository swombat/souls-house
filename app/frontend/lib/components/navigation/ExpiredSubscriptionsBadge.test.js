import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import ExpiredSubscriptionsBadge from './ExpiredSubscriptionsBadge.svelte';

test('expired subscriptions show as a black count, nothing when zero', async () => {
  const { rerender, container } = render(ExpiredSubscriptionsBadge, { count: 0 });
  expect(container.textContent.trim()).toBe('');
  await rerender({ count: 2 });
  const badge = screen.getByLabelText('2 expired subscriptions');
  expect(badge).toHaveTextContent('2');
  expect(badge.className).toContain('bg-neutral-950');
  expect(badge.className).not.toContain('bg-red');
});
