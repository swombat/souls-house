import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import SongReferenceCard from './SongReferenceCard.svelte';
import MessageBubble from './MessageBubble.svelte';

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

const youtube = { provider: 'youtube', embed_id: 'y8AWFf7EAc4', label: 'YouTube', url: 'https://youtu.be/y8AWFf7EAc4' };
const song = {
  title: 'A song',
  artist: 'An artist',
  links: [youtube],
  lyrics_state: 'present',
  lyrics: 'First line\nSecond line\n\nNext stanza',
};
const response = (value = song) => ({ ok: true, json: async () => ({ song: value }) });
function mockFetch(value = song) {
  const fetch = vi.fn().mockResolvedValue(response(value));
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

test('loads local JSON, but mounts no player until Play; lyrics expand separately', async () => {
  const fetch = mockFetch();
  const { container } = render(SongReferenceCard, { accountId: 'account', songId: 'song' });
  await screen.findByText('A song');
  expect(fetch).toHaveBeenCalledWith(
    '/accounts/account/field/songs/song',
    expect.objectContaining({ cache: 'no-store', signal: expect.any(AbortSignal) })
  );
  expect(container.querySelector('iframe, audio, img')).toBeNull();
  expect(screen.getByRole('link', { name: 'Open in Field' })).toHaveAttribute('target', '_blank');
  expect(screen.queryByTestId('song-card-lyrics')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Show lyrics' }));
  expect(screen.getByTestId('song-card-lyrics').textContent).toContain('First line\nSecond line');
  expect(container.querySelector('iframe, audio')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Play' }));
  await waitFor(() => expect(container.querySelector('iframe')).not.toBeNull());
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(container.querySelector('iframe')).toHaveAttribute(
    'src',
    'https://www.youtube-nocookie.com/embed/y8AWFf7EAc4'
  );
});

test('audio is preferred to an embed, with no audio request before click', async () => {
  mockFetch({ ...song, audio: { url: '/private/audio' } });
  const { container } = render(SongReferenceCard, { accountId: 'account', songId: 'song' });
  await screen.findByText('A song');
  expect(container.querySelector('audio, iframe')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Play' }));
  await waitFor(() => expect(container.querySelector('audio')).not.toBeNull());
  expect(container.querySelector('audio')).toHaveAttribute('preload', 'none');
  expect(container.querySelector('audio')).toHaveAttribute('src', '/private/audio');
  expect(container.querySelector('iframe')).toBeNull();
});

test('a discard between rendering and Play clears cached content and never plays', async () => {
  const fetch = mockFetch();
  const { container } = render(SongReferenceCard, { accountId: 'account', songId: 'song' });
  await screen.findByText('A song');
  fetch.mockResolvedValue({ ok: false });
  await fireEvent.click(screen.getByRole('button', { name: 'Play' }));
  await screen.findByText('Song unavailable');
  expect(screen.queryByText('A song')).toBeNull();
  expect(container.querySelector('audio, iframe, a')).toBeNull();
});

test('failures are generic and retry can resolve the current song', async () => {
  const fetch = mockFetch();
  fetch.mockRejectedValueOnce(new Error('private internal error'));
  render(SongReferenceCard, { accountId: 'account', songId: 'song' });
  await screen.findByText('Song unavailable');
  expect(screen.queryByText(/private internal/)).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Retry' }));
  await screen.findByText('A song');
});

test.each([
  ['missing', 'No lyrics yet'],
  ['instrumental', 'Instrumental, no lyrics.'],
])('labels %s lyrics and preserves non-embeddable fallback links', async (lyrics_state, label) => {
  mockFetch({
    ...song,
    lyrics_state,
    links: [{ provider: 'other', label: 'Website', url: 'https://example.com/song' }],
  });
  render(SongReferenceCard, { accountId: 'account', songId: 'song' });
  await screen.findByText(label);
  expect(screen.queryByRole('button', { name: 'Play' })).toBeNull();
  expect(screen.getByRole('link', { name: 'Open on Website' })).toHaveAttribute('href', 'https://example.com/song');
});

test('account/song changes hide old private content, abort requests, and ignore late results', async () => {
  const fetch = mockFetch();
  const { rerender } = render(SongReferenceCard, { accountId: 'first', songId: 'one' });
  await screen.findByText('A song');
  let resolveOld;
  fetch.mockImplementationOnce(() => new Promise((resolve) => (resolveOld = resolve)));
  await rerender({ accountId: 'second', songId: 'two' });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(2));
  const oldSignal = fetch.mock.calls[1][1].signal;
  expect(screen.queryByText('A song')).toBeNull();
  fetch.mockResolvedValue(response({ ...song, title: 'Current account song' }));
  await rerender({ accountId: 'third', songId: 'three' });
  await screen.findByText('Current account song');
  expect(oldSignal.aborted).toBe(true);
  resolveOld(response({ ...song, title: 'Secret stale song' }));
  await Promise.resolve();
  expect(screen.queryByText('Secret stale song')).toBeNull();
});

test('unmount aborts its fetch', async () => {
  const fetch = mockFetch();
  fetch.mockImplementation(() => new Promise(() => {}));
  const { unmount } = render(SongReferenceCard, { accountId: 'account', songId: 'song' });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  const signal = fetch.mock.calls[0][1].signal;
  unmount();
  expect(signal.aborted).toBe(true);
});

test('resident paragraph hook resolves a reference in place', async () => {
  const fetch = mockFetch();
  render(MessageBubble, {
    accountId: 'account',
    message: {
      role: 'assistant',
      content: 'Before.\n\n[[song:Song123]]\n\nAfter.',
      created_at: '2026-10-15T10:00:00Z',
    },
  });
  await screen.findByText('A song');
  expect(screen.getByText('Before.')).toBeTruthy();
  expect(screen.getByText('After.')).toBeTruthy();
  expect(fetch.mock.calls[0][0]).toBe('/accounts/account/field/songs/Song123');
});

test('a fresh serialization of the same message preserves the open card', async () => {
  const fetch = mockFetch();
  const message = {
    id: 'message',
    role: 'assistant',
    content: '[[song:Song123]]',
    created_at: '2026-10-15T10:00:00Z',
  };
  const { rerender } = render(MessageBubble, { accountId: 'account', message });
  await screen.findByText('A song');
  await fireEvent.click(screen.getByRole('button', { name: 'Show lyrics' }));
  await rerender({ accountId: 'account', message: { ...message } });
  await waitFor(() => expect(screen.getByRole('button', { name: 'Hide lyrics' })).toBeTruthy());
  expect(fetch).toHaveBeenCalledTimes(1);
});

test('human messages do not interpret resident song references', async () => {
  const fetch = mockFetch();
  const { container } = render(MessageBubble, {
    accountId: 'account',
    message: {
      role: 'user',
      content: '[[song:Song123]]',
      created_at: '2026-10-15T10:00:00Z',
    },
  });
  await Promise.resolve();
  expect(container.querySelector('[data-testid="song-card"]')).toBeNull();
  expect(fetch).not.toHaveBeenCalled();
});

test('leading blank lines do not prevent a plain paragraph reference', async () => {
  const fetch = mockFetch();
  render(MessageBubble, {
    accountId: 'account',
    message: {
      role: 'assistant',
      content: '\n\n[[song:Song123]]\n\n',
      created_at: '2026-10-15T10:00:00Z',
    },
  });
  await screen.findByText('A song');
  expect(fetch).toHaveBeenCalledTimes(1);
});

test.each([
  '`[[song:Song123]]`',
  '```\n[[song:Song123]]\n```',
  '    [[song:Song123]]',
  '\\[[song:Song123]]',
  'Prose [[song:Song123]]',
  'Before\n[[song:Song123]]\nAfter',
  '[[song:Song123]',
])('no card or fetch for literal/non-standalone reference: %s', async (content) => {
  const fetch = mockFetch();
  const { container } = render(MessageBubble, {
    accountId: 'account',
    message: { role: 'assistant', content, created_at: '2026-10-15T10:00:00Z' },
  });
  await Promise.resolve();
  expect(container.querySelector('[data-testid="song-card"]')).toBeNull();
  expect(fetch).not.toHaveBeenCalled();
});
