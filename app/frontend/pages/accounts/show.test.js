import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { tick } from 'svelte';
import { expect, test, vi } from 'vitest';
import General from './show.svelte';

const subscribe = vi.hoisted(() => vi.fn(() => vi.fn()));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));

const props = {
  account: { id: 'first', name: 'First', personal: false, created_at: '2026-01-01' },
  can_manage: true,
  can_be_personal: true,
  members_count: 1,
};
const name = () => screen.getByLabelText('Account name');
const input = (element, value) => fireEvent.input(element, { target: { value: String(value) } });
const submit = (element) => fireEvent.submit(element.closest('form'));
const response = (value, limit, id = 'first') => ({
  props: { account: { ...props.account, id, name: value }, resident_handoff_cap: limit },
});

test('General follows pristine baselines, updates derived permissions and keeps subscriptions stable', async () => {
  const view = render(General, props);
  expect(subscribe).toHaveBeenCalledWith('Account', 'first', [
    'account',
    'can_be_personal',
    'members_count',
    'can_manage',
  ]);
  const cleanup = subscribe.mock.results[0].value;
  await view.rerender({ ...props, account: { ...props.account, name: 'Remote' }, can_be_personal: false });
  expect(name()).toHaveValue('Remote');
  expect(screen.queryByRole('button', { name: 'Convert to personal account' })).not.toBeInTheDocument();
  expect(subscribe).toHaveBeenCalledTimes(1);
  expect(cleanup).not.toHaveBeenCalled();

  await input(name(), 'My name draft');
  await view.rerender({ ...props, account: { ...props.account, name: 'Remote again' } });
  expect(name()).toHaveValue('My name draft');
  view.unmount();
  expect(cleanup).toHaveBeenCalledOnce();
});

test('General holds only the name, the logo colour and the account type', () => {
  render(General, { ...props, logo_colour_options: ['teal', 'sky'] });
  expect(screen.getByRole('radiogroup', { name: 'Logo colour' })).toBeVisible();
  expect(screen.queryByTestId('resident-handoff-cap')).toBeNull();
  expect(screen.queryByTestId('show-chat-codes')).toBeNull();
  expect(screen.queryByTestId('voice-mode-enabled')).toBeNull();
});

test.each([['name', name, 'Submitted', 'Newer edit', 'Remote', 'Accepted', (value) => response(value, 6)]])(
  '%s saves acknowledge only the submitted edit, preserving dirty and in-flight drafts',
  async (kind, field, submitted, newer, remote, accepted, pageFor) => {
    const view = render(General, props);
    await input(field(), submitted);
    await submit(field());
    const [path, data, options] = router.put.mock.calls.at(-1);
    expect(path).toBe('/accounts/first');
    expect(data.account).toEqual(kind === 'name' ? { name: submitted } : { resident_handoff_cap: submitted });
    expect(options).toMatchObject({ preserveState: true, preserveScroll: true });
    await view.rerender({
      ...props,
      ...(kind === 'name' ? { account: { ...props.account, name: remote } } : { resident_handoff_cap: remote }),
    });
    expect(field()).toHaveValue(submitted);
    expect(field().closest('form').querySelector('button[type="submit"]')).toBeDisabled();
    await input(field(), newer);
    options.onSuccess(pageFor(accepted));
    options.onFinish();
    await tick();
    expect(field()).toHaveValue(newer);

    // Returning to the acknowledged baseline makes this pristine again.
    await input(field(), accepted);
    await view.rerender({
      ...props,
      ...(kind === 'name' ? { account: { ...props.account, name: 'Latest' } } : { resident_handoff_cap: 11 }),
    });
    expect(field()).toHaveValue(kind === 'name' ? 'Latest' : 11);
  }
);

test('successful unchanged name save adopts normalization, but a newer generation keeps its whitespace', async () => {
  render(General, props);
  await input(name(), ' Saved ');
  await submit(name());
  let options = router.put.mock.calls.at(-1)[2];
  expect(router.put.mock.calls.at(-1)[1]).toEqual({ account: { name: 'Saved' } });
  options.onSuccess(response('Saved', 6));
  options.onFinish();
  await tick();
  expect(name()).toHaveValue('Saved');
  await input(name(), ' Next ');
  await submit(name());
  options = router.put.mock.calls.at(-1)[2];
  await input(name(), 'Something else');
  await input(name(), ' Next ');
  options.onSuccess(response('Next', 6));
  options.onFinish();
  await tick();
  expect(name()).toHaveValue(' Next ');
});

test('late callbacks from an earlier save cannot acknowledge or finish a newer same-account request', async () => {
  const view = render(General, props);
  await input(name(), 'First save');
  await submit(name());
  const old = router.put.mock.calls.at(-1)[2];
  old.onSuccess(response('First save', 6));
  old.onFinish();
  await view.rerender({ ...props, account: { ...props.account, name: 'First save' } });
  await input(name(), 'Second save');
  await submit(name());
  const latest = router.put.mock.calls.at(-1)[2];
  old.onSuccess(response('Late old result', 6));
  old.onFinish();
  await tick();
  expect(name()).toHaveValue('Second save');
  expect(screen.getByRole('button', { name: 'Saving…' })).toBeDisabled();
  latest.onSuccess(response('Second save', 6));
  latest.onFinish();
  await tick();
  expect(name()).toHaveValue('Second save');
});

test.each([['name', name, 'Refused name']])(
  '%s redirect-alert refusals keep the submitted draft',
  async (kind, field, value) => {
    render(General, props);
    await input(field(), value);
    await submit(field());
    const options = router.put.mock.calls.at(-1)[2];
    options.onSuccess({
      props: { ...response('First', 6).props, flash: { alert: 'Account settings could not be saved.' } },
    });
    options.onFinish();
    await tick();
    expect(field()).toHaveValue(value);
    expect(field().closest('form').querySelector('button[type="submit"]')).not.toBeDisabled();
  }
);

test.each([['name', name, 'Old draft', 'New account draft']])(
  '%s resets on account switch and ignores old-account success and finish callbacks',
  async (kind, field, oldValue, newValue) => {
    const view = render(General, props);
    await input(field(), oldValue);
    await submit(field());
    const old = router.put.mock.calls.at(-1)[2];
    await view.rerender({
      ...props,
      account: { ...props.account, id: 'second', name: 'Second' },
      resident_handoff_cap: 2,
    });
    expect(field()).toHaveValue(kind === 'name' ? 'Second' : 2);
    await input(field(), newValue);
    await submit(field());
    const latest = router.put.mock.calls.at(-1)[2];
    expect(router.put.mock.calls.at(-1)[0]).toBe('/accounts/second');
    old.onSuccess(response('Old accepted', 15));
    old.onFinish();
    await tick();
    expect(field()).toHaveValue(newValue);
    expect(field().closest('form').querySelector('button[type="submit"]')).toBeDisabled();
    latest.onFinish(); // A refusal/failed visit acknowledges no baseline.
    await tick();
    expect(field()).toHaveValue(newValue);
    expect(field().closest('form').querySelector('button[type="submit"]')).not.toBeDisabled();
    expect(subscribe).toHaveBeenLastCalledWith('Account', 'second', expect.any(Array));
  }
);
