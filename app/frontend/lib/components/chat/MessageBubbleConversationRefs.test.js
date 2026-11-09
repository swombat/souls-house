import { render, cleanup, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import MessageBubble from './MessageBubble.svelte';
import { resetConversationTitlesForTest } from '$lib/conversation-titles.svelte.js';
import { resetCommitStatusesForTest } from '$lib/commit-status.svelte.js';

const { pageStore } = await vi.hoisted(async () => {
  const { writable } = await import('svelte/store');
  return { pageStore: writable({ props: {} }) };
});
vi.mock('@inertiajs/svelte', async (importOriginal) => ({ ...(await importOriginal()), page: pageStore }));

const content = [
  'Built in eqRAMj, reviewed in `YZxGbj`, not in xyzABC, on my iPhone.',
  '',
  '```',
  'souls show eqRAMj',
  '```',
].join('\n');

let fetchMock;

beforeEach(() => {
  resetConversationTitlesForTest();
  resetCommitStatusesForTest();
  pageStore.set({ props: { account: { id: 'acct1' }, commit_badges: { house_repo: null, repos: [] } } });
  fetchMock = vi.fn(async () => ({
    ok: true,
    json: async () => ({ titles: { eqRAMj: 'Companion menu bar', YZxGbj: 'Voyage recall' } }),
  }));
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function links(container) {
  return [...container.querySelectorAll('a[data-conversation-ref]')].map((a) => [
    a.dataset.conversationRef,
    a.textContent,
    a.getAttribute('href'),
  ]);
}

for (const role of ['user', 'assistant']) {
  test(`${role} messages link conversations the server names, in one batched lookup`, async () => {
    const { container } = render(MessageBubble, {
      message: { id: 1, role, content, streaming: false, created_at: '2026-11-09T12:00:00Z' },
    });

    await waitFor(() =>
      expect(links(container)).toEqual([
        ['eqRAMj', 'Companion menu bar', '/accounts/acct1/chats/eqRAMj'],
        ['YZxGbj', 'Voyage recall', '/accounts/acct1/chats/YZxGbj'],
      ])
    );
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(
      '/accounts/acct1/conversation_titles?ids=eqRAMj%2CYZxGbj%2CxyzABC%2CiPhone'
    );

    // Unknown IDs and shape-alike words read exactly as written.
    const text = container.textContent.replace(/\s+/g, ' ');
    expect(text).toContain('not in xyzABC, on my iPhone.');
    expect(container.querySelector('pre, [data-streamdown-code]')?.querySelector('a') ?? null).toBeNull();
    expect(container.querySelector('a[data-conversation-ref="eqRAMj"]').getAttribute('title')).toBe(
      'Conversation eqRAMj'
    );
  });
}

test('no lookups while a message is still streaming', async () => {
  const { container } = render(MessageBubble, {
    message: { id: 2, role: 'assistant', content: 'See eqRAMj', streaming: true, created_at: '2026-11-09T12:00:00Z' },
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  expect(fetchMock).not.toHaveBeenCalled();
  expect(container.textContent).toContain('See eqRAMj');
});

test('a failed lookup leaves the IDs as plain text', async () => {
  fetchMock = vi.fn(async () => ({ ok: false, json: async () => ({}) }));
  vi.stubGlobal('fetch', fetchMock);
  const { container } = render(MessageBubble, {
    message: { id: 3, role: 'user', content: 'See eqRAMj', streaming: false, created_at: '2026-11-09T12:00:00Z' },
  });
  await waitFor(() => expect(fetchMock).toHaveBeenCalledTimes(1));
  await new Promise((resolve) => setTimeout(resolve, 50));
  expect(links(container)).toEqual([]);
  expect(container.textContent).toContain('See eqRAMj');
});
