import { fireEvent, render, screen } from '@testing-library/svelte';
import { readable } from 'svelte/store';
import { vi } from 'vitest';

// Voice mode from New Chat (YMaddY): the empty composer offers the wave, and
// the wave creates the conversation with no opening message, arming voice mode
// for the conversation page that loads next.
vi.mock('@inertiajs/svelte', async (importOriginal) => ({
  ...(await importOriginal()),
  page: readable({
    props: { errors: {}, flash: {}, rooms: [], main_room_name: 'Main', current_room: 'main' },
    url: '/',
  }),
}));

import { router } from '@inertiajs/svelte';
import NewChatForm from './NewChatForm.svelte';
import { disarmVoiceStart, takeVoiceStart } from '$lib/voice-mode-start';

afterEach(() => vi.restoreAllMocks());

const base = {
  userId: 'user',
  account: { id: 'account' },
  agents: [{ id: 'resident', name: 'Resident' }],
};
const available = { offered: true, available: true, reason: null };

let post;
beforeEach(() => {
  localStorage.clear();
  post = vi.spyOn(router, 'post').mockImplementation(() => {});
  disarmVoiceStart();
});

test('without voice mode New Chat shows only Start conversation', () => {
  render(NewChatForm, base);
  expect(screen.queryByTestId('voice-mode-button')).toBeNull();
  expect(screen.getByRole('button', { name: 'Start conversation' })).toBeDisabled();
});

test('with voice mode the empty New Chat composer offers the wave', () => {
  render(NewChatForm, { ...base, voiceMode: available });
  expect(screen.getByRole('button', { name: 'Start voice mode' })).toHaveAttribute('aria-disabled', 'false');
  expect(screen.queryByRole('button', { name: 'Start conversation' })).toBeNull();
});

test('typing swaps the wave back for Start conversation', async () => {
  render(NewChatForm, { ...base, voiceMode: available });
  await fireEvent.input(screen.getByRole('textbox'), { target: { value: 'hello' } });
  expect(screen.queryByTestId('voice-mode-button')).toBeNull();
  expect(screen.getByRole('button', { name: 'Start conversation' })).toBeEnabled();
});

test('the wave creates the conversation with no message and arms voice mode', async () => {
  render(NewChatForm, { ...base, voiceMode: available });
  await fireEvent.click(screen.getByRole('button', { name: 'Start voice mode' }));
  expect(post).toHaveBeenCalledTimes(1);
  const [path, form, options] = post.mock.calls[0];
  expect(path).toContain('/accounts/account/chats');
  expect(form.get('message')).toBe('');
  expect(form.getAll('agent_ids[]')).toEqual(['resident']);
  // A conversation page arriving claims it.
  options.onSuccess({ component: 'chats/show', props: { flash: {} } });
  expect(takeVoiceStart()).toBe(true);
});

test('a refused start does not leave voice mode armed for a later conversation', async () => {
  render(NewChatForm, { ...base, voiceMode: available });
  await fireEvent.click(screen.getByRole('button', { name: 'Start voice mode' }));
  const [, , options] = post.mock.calls[0];
  options.onSuccess({ component: 'chats/new', props: { flash: {} } });
  expect(takeVoiceStart()).toBe(false);
});

test('with no resident selected there is no wave', () => {
  render(NewChatForm, { ...base, agents: [{ id: 'resident', name: 'Resident', paused: true }], voiceMode: available });
  expect(screen.queryByTestId('voice-mode-button')).toBeNull();
});
