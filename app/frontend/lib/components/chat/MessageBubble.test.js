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

test('ordinary grouped sections keep independent Markdown, files, tools and voice controls', async () => {
  const first = { id: 'a', role: 'assistant', content: '```text\nunclosed', created_at: '2026-09-28T08:00:00Z' };
  const second = {
    id: 'b',
    role: 'assistant',
    content: '**Checked.**',
    created_at: '2026-09-28T08:02:03Z',
    files_json: [{ id: 'file', filename: 'report.txt', content_type: 'text/plain', url: '/report.txt' }],
    tools_used: ['web_search'],
    voice_available: true,
  };
  const { container } = render(MessageBubble, { message: first, progressMessages: [first, second] });
  expect(container.querySelectorAll('section')).toHaveLength(2);
  expect(container.querySelector('strong')?.textContent).toBe('Checked.');
  expect(container.textContent).toContain('2m 03s elapsed');
  expect(container.textContent).toContain('report.txt');
  expect(container.querySelector('button[title="Play voice"]')).not.toBeNull();
  expect(container.textContent).not.toContain('Status unknown');
});
