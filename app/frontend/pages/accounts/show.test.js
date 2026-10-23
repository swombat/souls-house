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
  current_user_id: 1,
  resident_handoff_cap: 6,
  reflexes_enabled: false,
};
const name = () => screen.getByLabelText('Account name');
const cap = () => screen.getByTestId('resident-handoff-cap');
const input = (element, value) => fireEvent.input(element, { target: { value: String(value) } });
const submit = (element) => fireEvent.submit(element.closest('form'));
const response = (value, limit, id = 'first') => ({
  props: { account: { ...props.account, id, name: value }, resident_handoff_cap: limit },
});

test('General follows pristine baselines, updates derived permissions and keeps subscriptions stable', async () => {
  const view = render(General, props);
  expect(subscribe).toHaveBeenCalledWith('Account', 'first', [
    'account',
    'members',
    'can_be_personal',
    'can_manage',
    'resident_handoff_cap',
    'reflexes_enabled',
  ]);
  const cleanup = subscribe.mock.results[0].value;
  await view.rerender({
    ...props,
    account: { ...props.account, name: 'Remote' },
    resident_handoff_cap: 9,
    can_be_personal: false,
  });
  expect(name()).toHaveValue('Remote');
  expect(cap()).toHaveValue(9);
  expect(screen.queryByRole('button', { name: 'Convert to personal account' })).not.toBeInTheDocument();
  expect(subscribe).toHaveBeenCalledTimes(1);
  expect(cleanup).not.toHaveBeenCalled();

  await input(name(), 'My name draft');
  await input(cap(), 4);
  await view.rerender({ ...props, account: { ...props.account, name: 'Remote again' }, resident_handoff_cap: 12 });
  expect(name()).toHaveValue('My name draft');
  expect(cap()).toHaveValue(4);
  await view.rerender({ ...props, can_manage: false, resident_handoff_cap: 0 });
  expect(screen.getByTestId('resident-handoff-cap-readonly')).toHaveTextContent('Resident handoffs are off.');
  expect(screen.queryByRole('button', { name: 'Invite Member' })).not.toBeInTheDocument();
  view.unmount();
  expect(cleanup).toHaveBeenCalledOnce();
});

test.each([
  ['name', name, 'Submitted', 'Newer edit', 'Remote', 'Accepted', (value) => response(value, 6)],
  ['cap', cap, 7, 8, 9, 7, (value) => response('First', value)],
])(
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

test('handoff limits retain range validation and follow later baselines after an unchanged successful save', async () => {
  const view = render(General, props);
  for (const value of ['', -1, 51, 1.5]) {
    await input(cap(), value);
    await submit(cap());
    expect(router.put).not.toHaveBeenCalled();
  }
  await input(cap(), 0);
  await submit(cap());
  const options = router.put.mock.calls.at(-1)[2];
  options.onSuccess(response('First', 0));
  options.onFinish();
  await view.rerender({ ...props, resident_handoff_cap: 0 });
  await view.rerender({ ...props, resident_handoff_cap: 10 });
  expect(cap()).toHaveValue(10);
});

test.each([
  ['name', name, 'Refused name'],
  ['cap', cap, 7],
])('%s redirect-alert refusals keep the submitted draft', async (kind, field, value) => {
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
});

test.each([
  ['name', name, 'Old draft', 'New account draft'],
  ['cap', cap, 7, 8],
])(
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

test('invitation draft survives same-account updates and closes deliberately on account switch', async () => {
  const view = render(General, props);
  await fireEvent.click(screen.getByRole('button', { name: 'Invite Member' }));
  await input(screen.getByLabelText('Email Address'), 'unfinished@example.com');
  await view.rerender({ ...props, account: { ...props.account, name: 'Renamed remotely' } });
  expect(screen.getByLabelText('Email Address')).toHaveValue('unfinished@example.com');
  await view.rerender({ ...props, account: { ...props.account, id: 'second', name: 'Second' } });
  expect(screen.queryByLabelText('Email Address')).not.toBeInTheDocument();
});

test('reflexes switch saves immediately and the readonly text reflects the account setting', async () => {
  const view = render(General, props);
  await fireEvent.click(screen.getByTestId('reflexes-enabled'));
  const [path, data] = router.put.mock.calls.at(-1);
  expect(path).toBe('/accounts/first');
  expect(data).toEqual({ account: { reflexes_enabled: true } });

  await view.rerender({ ...props, can_manage: false, reflexes_enabled: true });
  expect(screen.getByTestId('reflexes-enabled-readonly')).toHaveTextContent('Reflexes are on for this account.');
});
