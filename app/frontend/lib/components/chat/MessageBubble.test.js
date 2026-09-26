import { render, cleanup, waitFor } from '@testing-library/svelte';
import { afterEach, expect, test } from 'vitest';
import MessageBubble from './MessageBubble.svelte';

afterEach(cleanup);

for (const role of ['user', 'assistant']) {
  test(`${role} completed prose does not invent a closing math delimiter`, () => {
    const content = 'Stored in $MIRA_ROOT/secrets/example.json for my own machines. Keep these words spaced.';
    const { container } = render(MessageBubble, {
      message: { role, content, created_at: '2026-09-26T12:00:00Z' },
    });
    expect(container.textContent).toContain(content);
    expect(container.querySelector('.katex')).toBeNull();
  });
}

test('completed messages still render deliberately delimited math', async () => {
  const { container } = render(MessageBubble, {
    message: { role: 'assistant', content: 'The result is $x^2$.', created_at: '2026-09-26T12:00:00Z' },
  });
  await waitFor(() => expect(container.querySelector('.katex')).not.toBeNull());
});

test('streaming messages still complete unfinished formatting', () => {
  const { container } = render(MessageBubble, {
    message: { role: 'assistant', content: '**Arriving words', streaming: true, created_at: '2026-09-26T12:00:00Z' },
  });
  expect(container.querySelector('strong')?.textContent).toBe('Arriving words');
});
