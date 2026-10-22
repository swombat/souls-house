import { render, fireEvent, screen, waitFor } from '@testing-library/svelte';
import { vi } from 'vitest';
vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));
import { subscribeToModel } from '$lib/cable';
import { router } from '@inertiajs/svelte';
import Voices from './voices.svelte';

const voice = { id: 'voice', name: 'Alice', used_in: 1, remember: true, remembered: false, recordings: 0 };
const props = { account: { id: 'home' }, voices: [voice] };
const begin = async () => {
  await fireEvent.click(screen.getByRole('button', { name: 'Rename', exact: true }));
  await fireEvent.input(screen.getByRole('textbox', { name: 'Name', exact: true }), {
    target: { value: 'Unfinished' },
  });
};

test('empty roster subscribes, stable refresh keeps subscription, account switch cleans up', async () => {
  const component = render(Voices, { account: props.account });
  await waitFor(() =>
    expect(subscribeToModel).toHaveBeenCalledWith('FieldVoiceActivity', 'home', [
      'voices',
      'recognise_voices',
      'can_change_setting',
      'voice_conversion',
    ])
  );
  const cleanup = subscribeToModel.mock.results.at(-1).value;
  const count = subscribeToModel.mock.calls.length;
  await component.rerender(props);
  expect(subscribeToModel).toHaveBeenCalledTimes(count);
  await component.rerender({ ...props, account: { id: 'next' } });
  await waitFor(() => expect(subscribeToModel).toHaveBeenCalledWith('FieldVoiceActivity', 'next', expect.anything()));
  expect(cleanup).toHaveBeenCalledOnce();
});

test('blocked conversion is visible, retry is manager-only and a live ready refresh clears it', async () => {
  const component = render(Voices, {
    ...props,
    can_change_setting: true,
    voice_conversion: { state: 'blocked', remaining: 1, message: 'One retained sample is unavailable.' },
  });
  expect(screen.getByTestId('voices-conversion')).toHaveTextContent('One retained sample is unavailable.');
  await fireEvent.click(screen.getByRole('button', { name: 'Retry voice conversion' }));
  expect(router.post).toHaveBeenCalledWith('/accounts/home/field/voices/retry_conversion');
  await component.rerender({
    ...props,
    can_change_setting: false,
    voice_conversion: { state: 'blocked', remaining: 1, message: 'One retained sample is unavailable.' },
  });
  expect(screen.queryByRole('button', { name: 'Retry voice conversion' })).not.toBeInTheDocument();
  await component.rerender({ ...props, voice_conversion: { state: 'ready', remaining: 0 } });
  expect(screen.queryByTestId('voices-conversion')).not.toBeInTheDocument();
});

test('remote rename and count refresh preserve draft; removal closes invalid form', async () => {
  const component = render(Voices, props);
  await begin();
  await component.rerender({ ...props, voices: [{ ...voice, name: 'Remote', used_in: 2 }] });
  expect(screen.getByRole('textbox', { name: 'Name', exact: true })).toHaveValue('Unfinished');
  expect(screen.getByText('named in 2 speakers · Name only so far')).toBeInTheDocument();
  await component.rerender({ ...props, voices: [] });
  await waitFor(() => expect(screen.queryByRole('textbox', { name: 'Name', exact: true })).not.toBeInTheDocument());
});

test('account switch resets rename; late response cannot close a new account draft', async () => {
  const component = render(Voices, props);
  await begin();
  await fireEvent.click(screen.getByRole('button', { name: 'Save', exact: true }));
  const callbacks = router.patch.mock.calls.at(-1)[2];
  await component.rerender({ ...props, account: { id: 'next' } });
  await waitFor(() => expect(screen.queryByRole('textbox', { name: 'Name', exact: true })).not.toBeInTheDocument());
  await begin();
  callbacks.onSuccess();
  callbacks.onFinish();
  expect(screen.getByRole('textbox', { name: 'Name', exact: true })).toHaveValue('Unfinished');
});

test('save acknowledgement does not discard a newer edit made during request', async () => {
  render(Voices, props);
  await begin();
  await fireEvent.click(screen.getByRole('button', { name: 'Save', exact: true }));
  const callbacks = router.patch.mock.calls.at(-1)[2];
  await fireEvent.input(screen.getByRole('textbox', { name: 'Name', exact: true }), {
    target: { value: 'Newer edit' },
  });
  callbacks.onSuccess();
  callbacks.onFinish();
  expect(screen.getByRole('textbox', { name: 'Name', exact: true })).toHaveValue('Newer edit');
  await waitFor(() => expect(screen.getByRole('button', { name: 'Save', exact: true })).not.toBeDisabled());
});
