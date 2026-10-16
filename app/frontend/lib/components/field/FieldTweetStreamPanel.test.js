import { render, fireEvent, screen } from '@testing-library/svelte';
import { tick } from 'svelte';
import { expect, test } from 'vitest';
import { router } from '@inertiajs/svelte';
import Panel from './FieldTweetStreamPanel.svelte';

const source = {
  id: 'source-one',
  handle: 'jack',
  url: 'https://x.com/jack',
  include_replies: true,
  include_quotes: true,
  include_reposts: false,
  own_monthly_usd_limit: '5.0',
  funding: 'own',
  state: 'syncing',
  collected_through: '2026-10-16T08:00:00Z',
  imported_today: 1,
  daily_import_cap: 100,
  backlog: 0,
};
const stream = {
  source,
  funding: 'own',
  integration_url: '/integrations',
  poll_minutes: 15,
  daily_import_cap: 100,
  house_available: true,
  account_monthly_usd_ceiling: 5,
};
const limit = () => screen.getByLabelText('Monthly limit on your TwitterAPI.io spend (USD)');
const replies = () => screen.getByLabelText('Include its replies');
const quotes = () => screen.getByLabelText('Include its quote-posts');
const reposts = () => screen.getByLabelText('Include its reposts');
const form = () => screen.getByTestId('tweet-stream-settings-form');
const editLimit = (value) => fireEvent.input(limit(), { target: { value } });
const response = (returned, accountId = 'one') => ({
  props: { account: { id: accountId }, tweet_stream: { ...stream, source: returned } },
});

function mount(initial = stream) {
  const component = render(Panel, { accountId: 'one', stream: initial });
  return {
    ...component,
    refresh: (changes) => component.rerender({ accountId: 'one', stream: { ...stream, ...changes } }),
  };
}

test('pristine settings accept remote edits and decimal representations compare numerically', async () => {
  const component = mount();
  await editLimit('5.00');
  await component.refresh({ source: { ...source, own_monthly_usd_limit: 5, imported_today: 2 } });
  expect(limit()).toHaveValue('5.00'); // status-only refresh does not rewrite even an equivalent string
  await component.refresh({ source: { ...source, own_monthly_usd_limit: '6.0', include_quotes: false } });
  expect(limit()).toHaveValue('6.0');
  expect(quotes()).not.toBeChecked();
  expect(screen.queryByText(/Settings changed elsewhere/)).not.toBeInTheDocument();
});

test.each(['', '6.', '.'])('dirty controls and partial decimal %j survive repeated status refreshes', async (value) => {
  const component = mount();
  await fireEvent.click(replies());
  await fireEvent.click(quotes());
  await fireEvent.click(reposts());
  await editLimit(value);
  for (let count = 2; count <= 4; count++) {
    await component.refresh({
      source: { ...source, imported_today: count, state: 'waiting', state_reason: 'Budget exhausted', backlog: count },
    });
    expect(limit()).toHaveValue(value);
    expect(replies()).not.toBeChecked();
    expect(quotes()).not.toBeChecked();
    expect(reposts()).toBeChecked();
    expect(screen.getByTestId('field-tweet-stream-state')).toHaveTextContent('Budget exhausted');
    expect(screen.getByText(new RegExp(`Imported today: ${count} of 100`))).toHaveTextContent(
      `${count} waiting in the backlog`
    );
  }
});

test('a dirty draft keeps its captured baseline across remote settings changes until reverted', async () => {
  const component = mount();
  await editLimit('7');
  await component.refresh({ source: { ...source, own_monthly_usd_limit: '6', include_quotes: false } });
  await component.refresh({ source: { ...source, own_monthly_usd_limit: '8', include_quotes: false } });
  expect(limit()).toHaveValue('7');
  expect(quotes()).toBeChecked();
  expect(screen.getByText(/Settings changed elsewhere/)).toBeInTheDocument();
  await editLimit('5'); // Revert to the captured baseline: now accept the newest server settings.
  expect(limit()).toHaveValue('8');
  expect(quotes()).not.toBeChecked();
});

test('same-source funding changes keep dirty options and the temporarily hidden limit', async () => {
  const component = mount();
  await editLimit('7.');
  await fireEvent.click(reposts());
  await component.refresh({ funding: 'house', source: { ...source, funding: 'house' } });
  expect(screen.queryByLabelText('Monthly limit on your TwitterAPI.io spend (USD)')).not.toBeInTheDocument();
  await component.refresh({ funding: null, source: { ...source, funding: null } });
  expect(reposts()).toBeChecked();
  await component.refresh({ source });
  expect(limit()).toHaveValue('7.');
  expect(reposts()).toBeChecked();
});

test.each(['error', 'redirect'])('a %s failure retains the draft and never acknowledges it', async (failure) => {
  const component = mount();
  await editLimit('7');
  await fireEvent.click(reposts());
  await fireEvent.submit(form());
  const [, data, callbacks] = router.patch.mock.calls[0];
  expect(data.field_tweet_source).toMatchObject({ own_monthly_usd_limit: '7', include_reposts: true });
  if (failure === 'error') callbacks.onError({ own_monthly_usd_limit: 'Invalid' });
  else {
    // This is the actual validation contract: redirect with an alert, no Inertia errors.
    callbacks.onSuccess({ ...response(source), props: { ...response(source).props, flash: { alert: 'Invalid' } } });
  }
  callbacks.onFinish();
  await component.refresh({ source: { ...source, imported_today: 10 } });
  expect(limit()).toHaveValue('7');
  expect(reposts()).toBeChecked();
  expect(screen.getByRole('alert')).toHaveTextContent('Your draft is still here');
  expect(screen.getByRole('button', { name: 'Save settings' })).toBeEnabled();
});

test.each(['account', 'source', 'values', 'missing'])('acknowledgement rejects mismatched %s', async (mismatch) => {
  const component = mount();
  await editLimit('7');
  await fireEvent.submit(form());
  const callbacks = router.patch.mock.calls[0][2];
  const returned = { ...source, own_monthly_usd_limit: '7' };
  if (mismatch === 'source') returned.id = 'other-source';
  if (mismatch === 'values') returned.include_quotes = false;
  callbacks.onSuccess(response(mismatch === 'missing' ? null : returned, mismatch === 'account' ? 'two' : 'one'));
  callbacks.onFinish();
  await tick();
  expect(limit()).toHaveValue('7');
  expect(screen.getByRole('alert')).toHaveTextContent('not confirmed');
  await component.refresh({ source: { ...source, own_monthly_usd_limit: '8' } });
  expect(limit()).toHaveValue('7');
});

test('verified save acknowledges the submitted values without erasing newer in-flight edits', async () => {
  const component = mount();
  await editLimit('7');
  await fireEvent.submit(form());
  expect(screen.getByRole('button', { name: 'Save settings' })).toBeDisabled();
  const callbacks = router.patch.mock.calls[0][2];
  await editLimit('8.');
  await fireEvent.click(replies());
  const returned = { ...source, own_monthly_usd_limit: '7.0' };
  await component.refresh({ source: returned });
  callbacks.onSuccess(response(returned));
  callbacks.onFinish();
  await component.refresh({ source: { ...returned, imported_today: 12 } });
  expect(limit()).toHaveValue('8.');
  expect(replies()).not.toBeChecked();
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();

  await editLimit('8');
  await fireEvent.submit(form());
  const second = router.patch.mock.calls[1][2];
  const saved = { ...returned, own_monthly_usd_limit: '8.0', include_replies: false };
  await component.refresh({ source: saved });
  second.onSuccess(response(saved));
  second.onFinish();
  await component.refresh({ source: { ...saved, own_monthly_usd_limit: '9.0', include_quotes: false } });
  expect(limit()).toHaveValue('9.0'); // An acknowledged, untouched draft is now pristine.
  expect(quotes()).not.toBeChecked();
});

test('source replacement resets settings and rejects detached submissions and late responses', async () => {
  const component = mount();
  await editLimit('7');
  const oldForm = form();
  await fireEvent.submit(oldForm);
  const callbacks = router.patch.mock.calls[0][2];
  const replacement = { ...source, id: 'source-two', handle: 'other', own_monthly_usd_limit: '2.0' };
  await component.refresh({ source: replacement });
  expect(limit()).toHaveValue('2.0');
  callbacks.onError({});
  callbacks.onSuccess(response({ ...source, own_monthly_usd_limit: '7.0' }));
  callbacks.onFinish();
  await fireEvent.submit(oldForm);
  expect(router.patch).toHaveBeenCalledTimes(1);
  expect(screen.queryByRole('alert')).not.toBeInTheDocument();
  await fireEvent.submit(form());
  expect(router.patch).toHaveBeenLastCalledWith(
    '/accounts/one/field/tweet_stream',
    { field_tweet_source: expect.objectContaining({ own_monthly_usd_limit: '2.0' }) },
    expect.any(Object)
  );
});

test('account switch resets even an equal source id and can only submit the new account settings', async () => {
  const component = mount();
  await editLimit('7');
  const oldForm = form();
  await component.rerender({
    accountId: 'two',
    stream: { ...stream, source: { ...source, own_monthly_usd_limit: '3' } },
  });
  expect(limit()).toHaveValue('3');
  await fireEvent.submit(oldForm);
  expect(router.patch).not.toHaveBeenCalled();
  await fireEvent.submit(form());
  expect(router.patch.mock.calls[0][0]).toBe('/accounts/two/field/tweet_stream');
  expect(router.patch.mock.calls[0][1].field_tweet_source.own_monthly_usd_limit).toBe('3');
});

test('source deletion and recreation deliberately discard both old settings and intervening follow drafts', async () => {
  const component = mount();
  await editLimit('7');
  await component.refresh({ source: null });
  expect(limit()).toHaveValue('5');
  await fireEvent.input(screen.getByLabelText('Follow an X handle'), { target: { value: 'draft-handle' } });
  await component.refresh({ source: { ...source, id: 'source-two', own_monthly_usd_limit: '2' } });
  expect(limit()).toHaveValue('2');
  await component.refresh({ source: null });
  expect(screen.getByLabelText('Follow an X handle')).toHaveValue('');
  expect(router.patch).not.toHaveBeenCalled();
});

test('follow handle, options and raw limit survive status and temporary funding loss; account switch resets', async () => {
  const component = mount({ ...stream, source: null });
  const followForm = screen.getByTestId('tweet-stream-follow-form');
  await fireEvent.input(screen.getByLabelText('Follow an X handle'), { target: { value: '@draft' } });
  await fireEvent.click(replies());
  await fireEvent.click(quotes());
  await fireEvent.click(reposts());
  await editLimit('6.');
  await component.refresh({ source: null, funding: null, poll_minutes: 30 });
  expect(followForm).not.toBeVisible();
  await fireEvent.submit(followForm);
  expect(router.post).not.toHaveBeenCalled();
  await component.refresh({ source: null, funding: 'house' });
  expect(screen.queryByLabelText('Monthly limit on your TwitterAPI.io spend (USD)')).not.toBeInTheDocument();
  await component.refresh({ source: null });
  expect(screen.getByLabelText('Follow an X handle')).toHaveValue('@draft');
  expect(limit()).toHaveValue('6.');
  expect(replies()).not.toBeChecked();
  expect(quotes()).not.toBeChecked();
  expect(reposts()).toBeChecked();
  await component.rerender({ accountId: 'two', stream: { ...stream, source: null } });
  expect(screen.getByLabelText('Follow an X handle')).toHaveValue('');
  expect(limit()).toHaveValue('5');
});

test('follow redirect failure retains its draft and sends only the current local values on retry', async () => {
  mount({ ...stream, source: null });
  await fireEvent.input(screen.getByLabelText('Follow an X handle'), { target: { value: '@draft' } });
  await editLimit('6');
  await fireEvent.submit(screen.getByTestId('tweet-stream-follow-form'));
  const callbacks = router.post.mock.calls[0][2];
  callbacks.onSuccess(response(null));
  callbacks.onFinish();
  await tick();
  expect(screen.getByRole('alert')).toHaveTextContent('not confirmed');
  expect(screen.getByLabelText('Follow an X handle')).toHaveValue('@draft');
  expect(limit()).toHaveValue('6');
  await fireEvent.submit(screen.getByTestId('tweet-stream-follow-form'));
  expect(router.post).toHaveBeenLastCalledWith(
    '/accounts/one/field/tweet_stream',
    { field_tweet_source: expect.objectContaining({ handle: 'draft', own_monthly_usd_limit: '6' }) },
    expect.any(Object)
  );
});

test('decimal text input preserves editing strings while browser validation enforces the previous amount bounds', async () => {
  mount();
  for (const value of ['', '5.', '-1', '100.01', '1.001']) {
    await editLimit(value);
    expect(limit()).toHaveValue(value);
    expect(limit().checkValidity()).toBe(false);
  }
  for (const value of ['0', '0.01', '5.0', '99.99', '100', '100.00']) {
    await editLimit(value);
    expect(limit().checkValidity()).toBe(true);
  }
});
