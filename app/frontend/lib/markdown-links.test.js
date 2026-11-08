import { render } from '@testing-library/svelte';
import { expect, test } from 'vitest';
import { Streamdown } from 'svelte-streamdown';
import { LINK_PREFIXES } from './markdown-links.js';

test('a bare email address renders as a mailto link, not [blocked]', async () => {
  const { container } = render(Streamdown, {
    content: 'Write to support@example.com or see https://example.com.',
    allowedLinkPrefixes: LINK_PREFIXES,
    parseIncompleteMarkdown: false,
  });
  await new Promise((r) => setTimeout(r, 0));
  expect(container.textContent).not.toContain('[blocked]');
  expect(container.querySelector('a[href="mailto:support@example.com"]')).not.toBeNull();
  expect(container.querySelector('a[href="https://example.com/"]')).not.toBeNull();
});

test('other schemes stay blocked', async () => {
  const { container } = render(Streamdown, {
    content: '[x](javascript:alert(1))',
    allowedLinkPrefixes: LINK_PREFIXES,
    parseIncompleteMarkdown: false,
  });
  await new Promise((r) => setTimeout(r, 0));
  expect(container.querySelector('a[href^="javascript"]')).toBeNull();
});
