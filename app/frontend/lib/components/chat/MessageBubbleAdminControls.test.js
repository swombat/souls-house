import { render, cleanup } from '@testing-library/svelte';
import { afterEach, expect, test } from 'vitest';
import MessageBubble from './MessageBubble.svelte';

afterEach(cleanup);

const message = (extra) => ({
  id: 'm1',
  role: 'user',
  content: 'Hello',
  created_at: '2026-10-26T12:00:00Z',
  editable: true,
  deletable: true,
  ...extra,
});

test("edit and delete on someone else's message are red for a site admin", () => {
  const { getByTitle } = render(MessageBubble, { message: message({ controls_admin_only: true }) });
  expect(getByTitle('Edit message (site admins only)').className).toContain('text-red-600');
  expect(getByTitle('Delete message (site admins only)').className).toContain('text-red-600');
});

test("the author's own edit and delete stay ordinary", () => {
  const { getByTitle } = render(MessageBubble, { message: message({ controls_admin_only: false }) });
  expect(getByTitle('Edit message').className).not.toContain('text-red-600');
  expect(getByTitle('Delete message').className).not.toContain('text-red-600');
});
