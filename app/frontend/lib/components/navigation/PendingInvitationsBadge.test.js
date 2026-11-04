import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import PendingInvitationsBadge from './PendingInvitationsBadge.svelte';

test('pending invitations show as a black envelope without a number, nothing when zero', async () => {
  const { rerender, container } = render(PendingInvitationsBadge, { count: 0 });
  expect(container.textContent.trim()).toBe('');
  expect(container.querySelector('svg')).toBeNull();
  await rerender({ count: 3 });
  const badge = screen.getByLabelText('Pending invitations');
  expect(badge.textContent.trim()).toBe('');
  expect(badge.querySelector('svg')).not.toBeNull();
  expect(badge.className).toContain('bg-neutral-950');
});
