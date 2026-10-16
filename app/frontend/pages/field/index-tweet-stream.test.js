import { render, fireEvent, screen } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import { router } from '@inertiajs/svelte';

vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
import FieldPage from './index.svelte';

const stream = {
  source: null,
  funding: 'own',
  integration_url: '/integrations',
  poll_minutes: 15,
  daily_import_cap: 100,
};
const props = { account: { id: 'one' }, field_empty: true, tweet_stream: stream };
const limit = () => screen.getByLabelText('Monthly limit on your TwitterAPI.io spend (USD)');

test('one stable panel preserves follow drafts across empty/nonempty relocation and tab switches', async () => {
  const component = render(FieldPage, props);
  const panel = screen.getByTestId('field-tweet-stream-panel');
  await fireEvent.input(screen.getByLabelText('Follow an X handle'), { target: { value: 'draft' } });
  await fireEvent.input(limit(), { target: { value: '7.' } });
  await fireEvent.click(screen.getByLabelText('Include its reposts'));
  await component.rerender({ ...props, field_empty: false, tab: 'tweets', counts: { all: 1, tweets: 1 } });
  expect(screen.getAllByTestId('field-tweet-stream-panel')).toEqual([panel]);
  expect(screen.getByLabelText('Follow an X handle')).toHaveValue('draft');
  expect(limit()).toHaveValue('7.');
  expect(screen.getByLabelText('Include its reposts')).toBeChecked();
  await component.rerender({ ...props, field_empty: false, tab: 'notes' });
  // Unit tests do not load Tailwind; the browser journey verifies visibility.
  expect(panel.parentElement).toHaveClass('hidden');
  await component.rerender({ ...props, field_empty: true });
  expect(panel).toBeVisible();
  expect(limit()).toHaveValue('7.');
});

test.each([false, true])(
  'feature-off intentionally resets the %s source form, including late callbacks',
  async (hasSource) => {
    const source = hasSource
      ? {
          id: 'source',
          handle: 'jack',
          url: 'https://x.com/jack',
          include_replies: true,
          include_quotes: true,
          include_reposts: false,
          own_monthly_usd_limit: '5',
          funding: 'own',
          state: 'syncing',
        }
      : null;
    const initial = { ...props, tweet_stream: { ...stream, source } };
    const component = render(FieldPage, initial);
    await fireEvent.input(limit(), { target: { value: '7.' } });
    if (!hasSource) {
      await fireEvent.input(screen.getByLabelText('Follow an X handle'), { target: { value: 'draft' } });
    }
    const oldForm = screen.getByTestId(hasSource ? 'tweet-stream-settings-form' : 'tweet-stream-follow-form');
    await fireEvent.submit(oldForm);
    const request = hasSource ? router.patch : router.post;
    const callbacks = request.mock.calls[0][2];
    await component.rerender({ ...props, tweet_stream: null });
    expect(screen.queryByTestId('field-tweet-stream-panel')).not.toBeInTheDocument();
    await component.rerender(initial);
    callbacks.onError({});
    callbacks.onSuccess({ props: { account: { id: 'one' }, tweet_stream: { ...stream, source } } });
    callbacks.onFinish();
    await fireEvent.submit(oldForm);
    expect(request).toHaveBeenCalledTimes(1);
    expect(screen.queryByRole('alert')).not.toBeInTheDocument();
    expect(limit()).toHaveValue('5');
    if (!hasSource) expect(screen.getByLabelText('Follow an X handle')).toHaveValue('');
  }
);
