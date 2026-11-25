import { fireEvent, render, screen } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { tick } from 'svelte';
import { expect, test, vi } from 'vitest';
import Features from './features.svelte';

const subscribe = vi.hoisted(() => vi.fn(() => vi.fn()));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));

const props = {
  account: { id: 'first', name: 'First', personal: false, created_at: '2026-01-01' },
  can_manage: true,
  resident_handoff_cap: 6,
  reflexes_enabled: false,
};
const cap = () => screen.getByTestId('resident-handoff-cap');
const input = (element, value) => fireEvent.input(element, { target: { value: String(value) } });
const submit = (element) => fireEvent.submit(element.closest('form'));
const response = (value, limit, id = 'first') => ({
  props: { account: { ...props.account, id, name: value }, resident_handoff_cap: limit },
});

test('Features follows pristine baselines and keeps subscriptions stable', async () => {
  const view = render(Features, props);
  expect(subscribe).toHaveBeenCalledWith('Account', 'first', [
    'account',
    'can_manage',
    'resident_handoff_cap',
    'telegram_bot_wake_limit',
    'reflexes_enabled',
    'show_chat_codes',
    'show_room_chat_counts',
    'plan_offer_enabled',
    'plan_offer_available',
    'voice_mode_enabled',
    'speech_engine',
    'eleven_labs_key_present',
    'eleven_labs_house_key',
  ]);
  const cleanup = subscribe.mock.results[0].value;
  await view.rerender({ ...props, resident_handoff_cap: 9 });
  expect(cap()).toHaveValue(9);
  expect(subscribe).toHaveBeenCalledTimes(1);
  expect(cleanup).not.toHaveBeenCalled();

  await input(cap(), 4);
  await view.rerender({ ...props, resident_handoff_cap: 12 });
  expect(cap()).toHaveValue(4);
  await view.rerender({ ...props, can_manage: false, resident_handoff_cap: 0 });
  expect(screen.getByTestId('resident-handoff-cap-readonly')).toHaveTextContent('Resident handoffs are off.');
  view.unmount();
  expect(cleanup).toHaveBeenCalledOnce();
});

test.each([['cap', cap, 7, 8, 9, 7, (value) => response('First', value)]])(
  '%s saves acknowledge only the submitted edit, preserving dirty and in-flight drafts',
  async (kind, field, submitted, newer, remote, accepted, pageFor) => {
    const view = render(Features, props);
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

test('handoff limits retain range validation and follow later baselines after an unchanged successful save', async () => {
  const view = render(Features, props);
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

test.each([['cap', cap, 7]])('%s redirect-alert refusals keep the submitted draft', async (kind, field, value) => {
  render(Features, props);
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

test.each([['cap', cap, 7, 8]])(
  '%s resets on account switch and ignores old-account success and finish callbacks',
  async (kind, field, oldValue, newValue) => {
    const view = render(Features, props);
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

test('reflexes switch saves immediately and the readonly text reflects the account setting', async () => {
  const view = render(Features, props);
  await fireEvent.click(screen.getByTestId('reflexes-enabled'));
  const [path, data] = router.put.mock.calls.at(-1);
  expect(path).toBe('/accounts/first');
  expect(data).toEqual({ account: { reflexes_enabled: true } });

  await view.rerender({ ...props, can_manage: false, reflexes_enabled: true });
  expect(screen.getByTestId('reflexes-enabled-readonly')).toHaveTextContent('Reflexes are on for this account.');
});

test('reflexes card shows only while the account has the choice', async () => {
  const view = render(Features, { ...props, reflexes_site_scope: 'account_choice' });
  expect(screen.queryByTestId('reflexes-site-override')).toBeNull();
  expect(screen.getByTestId('reflexes-enabled')).toBeVisible();

  for (const scope of ['disabled', 'enabled']) {
    await view.rerender({ ...props, reflexes_site_scope: scope, reflexes_enabled: true });
    expect(screen.queryByTestId('reflexes-enabled')).toBeNull();
    expect(screen.queryByTestId('reflexes-site-override')).toBeNull();
  }
});

test('voice mode and voice engine show only while the site leaves them to the account', async () => {
  const view = render(Features, {
    ...props,
    voice_mode_site_scope: 'account_choice',
    speech_engine_site_scope: 'account_choice',
  });
  expect(screen.getByRole('heading', { name: 'Voice' })).toBeVisible();
  expect(screen.getByTestId('voice-mode-enabled')).toBeVisible();

  await view.rerender({ ...props, voice_mode_site_scope: 'enabled', speech_engine_site_scope: 'disabled' });
  expect(screen.queryByTestId('voice-mode-enabled')).toBeNull();
  expect(screen.queryByTestId('voice-mode-enabled-readonly')).toBeNull();
  expect(screen.getByTestId('voice-mode-site-override')).toHaveTextContent('on for every account');
  expect(screen.getByTestId('voice-mode-audio-path')).toBeInTheDocument();
  expect(screen.queryByTestId('speech-engine-phonon')).toBeNull();

  await view.rerender({ ...props, voice_mode_site_scope: 'disabled', speech_engine_site_scope: 'disabled' });
  expect(screen.queryByRole('heading', { name: 'Voice' })).toBeNull();
});

test('illustrated features keep their clip behind a Watch example disclosure', async () => {
  render(Features, { ...props, plan_offer_available: true, voice_mode_site_scope: 'account_choice' });
  for (const clip of ['conversation-codes', 'room-counts', 'long-task-plans', 'voice-mode']) {
    const disclosure = screen.getByTestId(`feature-clip-${clip}`);
    expect(disclosure.querySelector('video')).toBeNull();
    await fireEvent.click(disclosure.querySelector('summary'));
    disclosure.open = true;
    disclosure.dispatchEvent(new Event('toggle'));
    await tick();
    expect(disclosure.querySelector('video')).toHaveAttribute('src', `/changelog-clips/${clip}.mp4`);
  }
});

test('plans for long tasks switch saves immediately when the plan allows it', async () => {
  render(Features, { ...props, plan_offer_available: true, plan_offer_enabled: false });
  expect(screen.queryByTestId('plan-offer-unavailable')).toBeNull();
  await fireEvent.click(screen.getByTestId('plan-offer-enabled'));
  const [path, data] = router.put.mock.calls.at(-1);
  expect(path).toBe('/accounts/first');
  expect(data).toEqual({ account: { plan_offer_enabled: true } });
});

test('plans for long tasks is not shown outside Colleagues', () => {
  render(Features, { ...props, plan_offer_available: false, plan_offer_enabled: false });
  expect(screen.queryByTestId('plan-offer-enabled')).toBeNull();
  expect(screen.queryByTestId('plan-offer-unavailable')).toBeNull();
});

test('plans for long tasks switch is disabled with a note when left on after the plan lapsed, and readonly for non-managers', async () => {
  const view = render(Features, { ...props, plan_offer_available: false, plan_offer_enabled: true });
  expect(screen.getByTestId('plan-offer-enabled')).toBeDisabled();
  expect(screen.getByTestId('plan-offer-unavailable')).toHaveTextContent('Comes with the Colleagues plan.');

  await view.rerender({ ...props, can_manage: false, plan_offer_available: true, plan_offer_enabled: true });
  expect(screen.queryByTestId('plan-offer-enabled')).toBeNull();
  expect(screen.getByTestId('plan-offer-enabled-readonly')).toHaveTextContent('on for this account');
});
