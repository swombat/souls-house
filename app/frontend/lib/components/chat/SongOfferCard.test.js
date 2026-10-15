import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import SongOfferCard from './SongOfferCard.svelte';
import MessageBubble from './MessageBubble.svelte';

afterEach(() => {
  cleanup();
  document.querySelector('meta[name="csrf-token"]')?.remove();
  vi.unstubAllGlobals();
});

const link = { provider: 'youtube', embed_id: 'y8AWFf7EAc4', url: 'https://youtu.be/y8AWFf7EAc4' };
const offer = { url: link.url, title: 'Offered title', artist: 'Offered artist' };
const saved = { id: 'Saved123', title: 'Existing title', artist: 'Existing artist', lyrics: 'Private lyrics' };
const response = (song = null, approvedLink = link) => ({
  ok: true,
  json: async () => ({ link: approvedLink, song }),
});
function mockFetch() {
  const fetch = vi.fn().mockResolvedValue(response());
  vi.stubGlobal('fetch', fetch);
  return fetch;
}

test('unsaved offer validates locally, renders text, and makes no external load before Play', async () => {
  const fetch = mockFetch();
  const { container } = render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('button', { name: 'Add to Field' });
  expect(fetch).toHaveBeenCalledTimes(1);
  expect(fetch.mock.calls[0][0]).toBe('/accounts/account/field/songs/offer?url=https%3A%2F%2Fyoutu.be%2Fy8AWFf7EAc4');
  expect(screen.getByText('Offered title')).toBeTruthy();
  expect(screen.getByText('Offered artist')).toBeTruthy();
  expect(container.querySelector('iframe, audio, img')).toBeNull();
  await fireEvent.click(screen.getByRole('button', { name: 'Play' }));
  await waitFor(() => expect(container.querySelector('iframe')).not.toBeNull());
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(container.querySelector('iframe').src).toBe('https://www.youtube-nocookie.com/embed/y8AWFf7EAc4');
  expect(screen.queryByRole('button', { name: /lyrics/i })).toBeNull();
});

test('save is explicit, includes CSRF, disables in flight, and opens the returned Field song', async () => {
  const fetch = mockFetch();
  const meta = document.createElement('meta');
  meta.name = 'csrf-token';
  meta.content = 'test-csrf';
  document.head.append(meta);
  render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('button', { name: 'Add to Field' });
  let resolve;
  fetch.mockImplementationOnce(() => new Promise((done) => (resolve = done)));
  await fireEvent.click(screen.getByRole('button', { name: 'Add to Field' }));
  expect(screen.getAllByRole('button').every((button) => button.disabled)).toBe(true);
  expect(fetch.mock.calls[1]).toEqual([
    '/accounts/account/field/songs/offer',
    expect.objectContaining({
      method: 'POST',
      headers: expect.objectContaining({ 'X-CSRF-Token': 'test-csrf', 'Content-Type': 'application/json' }),
      body: JSON.stringify(offer),
    }),
  ]);
  resolve(response(saved));
  const field = await screen.findByRole('link', { name: 'Open in Field' });
  expect(field).toHaveAttribute('href', '/accounts/account/field?tab=songs&item=song-Saved123');
  expect(screen.queryByRole('button', { name: 'Add to Field' })).toBeNull();
  expect(screen.queryByText('Private lyrics')).toBeNull();
  expect(screen.getByText('Offered title')).toBeTruthy();
});

test('a failed save is not called saved and can be retried', async () => {
  const fetch = mockFetch();
  render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('button', { name: 'Add to Field' });
  fetch.mockResolvedValueOnce({ ok: false });
  await fireEvent.click(screen.getByRole('button', { name: 'Add to Field' }));
  await screen.findByText('Could not save to Field. Try again.');
  expect(screen.queryByRole('link', { name: 'Open in Field' })).toBeNull();
  fetch.mockResolvedValueOnce(response(saved));
  await fireEvent.click(screen.getByRole('button', { name: 'Add to Field' }));
  await screen.findByRole('link', { name: 'Open in Field' });
});

test('reloading an existing offer does not POST or replace metadata', async () => {
  const fetch = mockFetch();
  fetch.mockResolvedValue(response(saved));
  const { unmount } = render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('link', { name: 'Open in Field' });
  unmount();
  render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('link', { name: 'Open in Field' });
  expect(fetch).toHaveBeenCalledTimes(2);
  expect(fetch.mock.calls.every(([, options]) => options.method === 'GET')).toBe(true);
  expect(screen.queryByRole('button', { name: 'Add to Field' })).toBeNull();
});

test('missing title allows listening but cannot save', async () => {
  mockFetch();
  render(SongOfferCard, { accountId: 'account', offer: { ...offer, title: '' } });
  await screen.findByText('A title is needed to save this song.');
  expect(screen.getByText('Title needed')).toBeTruthy();
  expect(screen.queryByRole('button', { name: 'Add to Field' })).toBeNull();
  expect(screen.getByRole('button', { name: 'Play' })).toBeTruthy();
});

test.each([
  ['bandcamp', 'Bandcamp', 'https://example.bandcamp.com/track/test'],
  ['apple_music', 'Apple Music', 'https://music.apple.com/us/album/example/123'],
])('supported non-embed provider %s has only a server-approved Open link', async (provider, label, url) => {
  const fetch = mockFetch();
  fetch.mockResolvedValue(response(null, { provider, url }));
  const { container } = render(SongOfferCard, { accountId: 'account', offer });
  const open = await screen.findByRole('link', { name: `Open on ${label}` });
  expect(open).toHaveAttribute('href', url);
  expect(container.querySelector('iframe, audio, img')).toBeNull();
  expect(screen.queryByRole('button', { name: 'Play' })).toBeNull();
});

test('unsafe or unsupported URLs are unavailable, with no external link or save', async () => {
  const fetch = mockFetch();
  fetch.mockResolvedValue({ ok: false, status: 422 });
  const { container } = render(SongOfferCard, {
    accountId: 'account',
    offer: { ...offer, url: 'javascript:alert(1)' },
  });
  await screen.findByText('Song unavailable');
  expect(container.querySelector('iframe, audio, img, a')).toBeNull();
  expect(screen.queryByRole('button', { name: 'Add to Field' })).toBeNull();
  expect(fetch.mock.calls[0][0]).toContain('url=javascript%3Aalert%281%29');
});

test('Play revalidates; a newly unavailable offer never mounts a player', async () => {
  const fetch = mockFetch();
  const { container } = render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('button', { name: 'Play' });
  fetch.mockResolvedValueOnce({ ok: false });
  await fireEvent.click(screen.getByRole('button', { name: 'Play' }));
  await screen.findByText('Song unavailable');
  expect(container.querySelector('iframe, audio, a')).toBeNull();
});

test.each(['account', 'url', 'title', 'artist'])('%s changes abort and ignore stale saves', async (change) => {
  const fetch = mockFetch();
  const { rerender } = render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('button', { name: 'Add to Field' });
  let resolve;
  fetch.mockImplementationOnce(() => new Promise((done) => (resolve = done)));
  await fireEvent.click(screen.getByRole('button', { name: 'Add to Field' }));
  const signal = fetch.mock.calls[1][1].signal;
  fetch.mockResolvedValue(response(null, { ...link, provider: 'bandcamp', embed_id: null }));
  await rerender({
    accountId: change === 'account' ? 'new-account' : 'account',
    offer: change === 'account' ? { ...offer } : { ...offer, [change]: 'changed' },
  });
  await screen.findByRole('button', { name: 'Add to Field' });
  expect(signal.aborted).toBe(true);
  resolve(response(saved));
  await Promise.resolve();
  expect(screen.queryByRole('link', { name: 'Open in Field' })).toBeNull();
});

test('fresh paragraph props preserve playback without another validation request', async () => {
  const fetch = mockFetch();
  const { rerender, container } = render(SongOfferCard, { accountId: 'account', offer });
  await screen.findByRole('button', { name: 'Play' });
  await fireEvent.click(screen.getByRole('button', { name: 'Play' }));
  await waitFor(() => expect(container.querySelector('iframe')).not.toBeNull());
  await rerender({ accountId: 'account', offer: { ...offer } });
  expect(container.querySelector('iframe')).not.toBeNull();
  expect(fetch).toHaveBeenCalledTimes(2);
});

test('unmount aborts validation and ignores late results', async () => {
  const fetch = mockFetch();
  let resolve;
  fetch.mockImplementationOnce(() => new Promise((done) => (resolve = done)));
  const { unmount } = render(SongOfferCard, { accountId: 'account', offer });
  await waitFor(() => expect(fetch).toHaveBeenCalledTimes(1));
  const signal = fetch.mock.calls[0][1].signal;
  unmount();
  expect(signal.aborted).toBe(true);
  resolve(response(saved));
  await Promise.resolve();
  expect(screen.queryByRole('link', { name: 'Open in Field' })).toBeNull();
});

test('resident paragraphs route offers and display supplied escaped metadata as text', async () => {
  mockFetch();
  const { container } = render(MessageBubble, {
    accountId: 'account',
    message: {
      role: 'assistant',
      content: String.raw`[[song:https://youtu.be/y8AWFf7EAc4 | <img src=x> \| \[title\] | <b>artist</b>]]`,
      created_at: '2026-10-15T10:00:00Z',
    },
  });
  await screen.findByRole('button', { name: 'Add to Field' });
  expect(screen.getByText('<img src=x> | [title]')).toBeTruthy();
  expect(screen.getByText('<b>artist</b>')).toBeTruthy();
  expect(container.querySelector('img, iframe, audio')).toBeNull();
});
