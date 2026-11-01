import { render, screen } from '@testing-library/svelte';
import TweetCards from './TweetCards.svelte';

const tweet = {
  id: '2116625402898841824',
  url: 'https://x.com/JoshuaSWarren/status/2116625402898841824',
  author_handle: 'JoshuaSWarren',
  author_name: 'Joshua Warren',
  text: 'Plain <b>text</b> <img src=x onerror=alert(1)>',
  posted_at: '2026-10-30T09:00:00Z',
  media: [],
};

test('renders nothing without tweets', () => {
  const { container } = render(TweetCards, { tweets: [] });
  expect(container.querySelector('article')).toBeNull();
});

test('shows the post as text, never as HTML, with a link to X', () => {
  const { container } = render(TweetCards, { tweets: [tweet] });
  expect(screen.getByText(tweet.text)).toBeTruthy();
  expect(container.querySelector('article b')).toBeNull();
  expect(container.querySelector('article p img')).toBeNull();
  expect(screen.getByText('@JoshuaSWarren')).toBeTruthy();
  expect(screen.getByText('View on X').getAttribute('href')).toBe(tweet.url);
});

test('shows media and a quoted post when present', () => {
  const { container } = render(TweetCards, {
    tweets: [
      {
        ...tweet,
        text: 'with a picture',
        media: [{ type: 'photo', url: 'https://pbs.twimg.com/media/a.jpg', alt: 'a cat' }],
        quoted: { id: '77', author_handle: 'someone', text: 'the original' },
      },
    ],
  });
  expect(container.querySelector('img').getAttribute('src')).toBe('https://pbs.twimg.com/media/a.jpg');
  expect(container.querySelector('img').getAttribute('alt')).toBe('a cat');
  expect(screen.getByText('the original')).toBeTruthy();
});
