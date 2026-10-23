import { render, cleanup, waitFor } from '@testing-library/svelte';
import { afterEach, beforeEach, expect, test, vi } from 'vitest';
import MessageBubble from './MessageBubble.svelte';
import { resetCommitStatusesForTest } from '$lib/commit-status.svelte.js';

const { pageStore } = await vi.hoisted(async () => {
  const { writable } = await import('svelte/store');
  return {
    pageStore: writable({
      props: {
        user: { site_admin: true },
        account: { id: 'acct1' },
        commit_badges: { house_repo: 'swombat/souls-house', repos: [] },
      },
    }),
  };
});
vi.mock('@inertiajs/svelte', async (importOriginal) => ({ ...(await importOriginal()), page: pageStore }));

const content = [
  'Live in 51625a7, merged as `783ab2e`, branch 9c8b7a6, unknown abcdef1.',
  '',
  'Chaos is https://github.com/swombat/chaos/commit/51625a7795b2b2369a1aafa009b63093dcafc7d3',
  '',
  '```',
  'git revert 51625a7',
  '```',
].join('\n');

let fetchMock;

beforeEach(() => {
  resetCommitStatusesForTest();
  pageStore.set({
    props: {
      user: { site_admin: true },
      account: { id: 'acct1' },
      commit_badges: { house_repo: 'swombat/souls-house', repos: [] },
    },
  });
  fetchMock = vi.fn(async () => ({
    ok: true,
    json: async () => ({
      statuses: { '51625a7': 'deployed', '783ab2e': 'merged', '9c8b7a6': 'unmerged', abcdef1: null },
    }),
  }));
  vi.stubGlobal('fetch', fetchMock);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

function badges(container) {
  return [...container.querySelectorAll('[data-commit-status]')].map((el) => el.dataset.commitStatus);
}

for (const role of ['user', 'assistant']) {
  test(`${role} messages badge commits of this repository in one batched lookup`, async () => {
    const { container } = render(MessageBubble, {
      message: { id: 1, role, content, streaming: false, created_at: '2026-10-04T12:00:00Z' },
    });

    await waitFor(() => expect(badges(container)).toEqual(['deployed', 'merged', 'unmerged']));
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(fetchMock.mock.calls[0][0]).toBe(
      '/accounts/acct1/commit_statuses?refs=51625a7%2C783ab2e%2C9c8b7a6%2Cabcdef1'
    );

    // The text itself is unchanged: badges are icons, not characters.
    expect(container.textContent.replace(/\s+/g, ' ')).toContain(
      'Live in 51625a7, merged as 783ab2e, branch 9c8b7a6, unknown abcdef1.'
    );
    expect(
      container.querySelector('pre, [data-streamdown-code]')?.querySelector('[data-commit-status]') ?? null
    ).toBeNull();
    expect(container.querySelector('code')?.textContent).toBe('783ab2e');
  });
}

test('no lookups while a message is still streaming', async () => {
  render(MessageBubble, {
    message: {
      id: 2,
      role: 'assistant',
      content: 'Merged as 51625a7',
      streaming: true,
      created_at: '2026-10-04T12:00:00Z',
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  expect(fetchMock).not.toHaveBeenCalled();
});

test('readers with no badge repositories get no lookups and no badges', async () => {
  pageStore.set({
    props: { user: { site_admin: false }, account: { id: 'acct1' }, commit_badges: { house_repo: null, repos: [] } },
  });
  const { container } = render(MessageBubble, {
    message: {
      id: 3,
      role: 'user',
      content: 'Merged as 51625a7',
      streaming: false,
      created_at: '2026-10-04T12:00:00Z',
    },
  });
  await new Promise((resolve) => setTimeout(resolve, 150));
  expect(fetchMock).not.toHaveBeenCalled();
  expect(badges(container)).toEqual([]);
  expect(container.textContent).toContain('Merged as 51625a7');
});

test("an account's own repository badges its commit URLs, and other repositories' URLs stay plain", async () => {
  pageStore.set({
    props: {
      user: { site_admin: false },
      account: { id: 'acct1' },
      commit_badges: { house_repo: null, repos: ['Acme/Web'] },
    },
  });
  fetchMock = vi.fn(async () => ({
    ok: true,
    json: async () => ({ statuses: { 'acme/web@783ab2e': 'on_default' }, revision: 'acme/web=fff' }),
  }));
  vi.stubGlobal('fetch', fetchMock);

  const { container } = render(MessageBubble, {
    message: {
      id: 4,
      role: 'user',
      content: 'See https://github.com/Acme/Web/commit/783ab2e and https://github.com/swombat/chaos/commit/51625a7',
      streaming: false,
      created_at: '2026-10-04T12:00:00Z',
    },
  });

  await waitFor(() => expect(badges(container)).toEqual(['on_default']));
  // An account's repository is measured against its own default branch: no
  // "master", no deployment.
  const badge = container.querySelector('[data-commit-status]');
  expect(badge.getAttribute('title')).toBe('On the default branch');
  expect(badge.getAttribute('aria-label')).toBe('On the default branch');
  expect(fetchMock).toHaveBeenCalledTimes(1);
  expect(fetchMock.mock.calls[0][0]).toBe('/accounts/acct1/commit_statuses?refs=acme%2Fweb%40783ab2e');
  expect([...container.querySelectorAll('a')].map((a) => a.getAttribute('href'))).toEqual([
    'https://github.com/Acme/Web/commit/783ab2e',
    'https://github.com/swombat/chaos/commit/51625a7',
  ]);
});
