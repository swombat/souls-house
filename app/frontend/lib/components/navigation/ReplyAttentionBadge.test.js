import { render, screen } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import ReplyAttentionBadge from './ReplyAttentionBadge.svelte';

test('empty counts are invisible; positive counts are labelled and visually bounded', async () => {
  const { rerender, container } = render(ReplyAttentionBadge, { count: 0 });
  expect(container.textContent.trim()).toBe('');
  await rerender({ count: 1 });
  expect(screen.getByLabelText('1 thread requests your response')).toHaveTextContent('1');
  await rerender({ count: 123 });
  expect(screen.getByLabelText('123 threads request your response')).toHaveTextContent('99+');
});
