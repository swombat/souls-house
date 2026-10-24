import { fireEvent, render, screen, waitFor } from '@testing-library/svelte';
import { router } from '@inertiajs/svelte';
import { vi } from 'vitest';
import EditResident from './edit.svelte';
import { subscribeToModel } from '$lib/cable';

vi.mock('$lib/cable', () => ({ subscribeToModel: vi.fn(() => vi.fn()) }));

const telegramProps = ['telegram_configuration', 'telegram_subscriber_count'];
const props = {
  account: { id: 'home' },
  agent: { id: 'resident', name: 'Resident', telegram_configured: false, telegram_bot_username: 'stale_bot' },
  telegram_configuration: { configured: true, username: 'incoming_bot' },
  telegram_subscriber_count: 2,
  active_tab: 'integrations',
};

test('Telegram maps exactly configuration/count to the stable resident identity, never the bearer link', async () => {
  const view = render(EditResident, props);
  const calls = () => subscribeToModel.mock.calls.filter(([model]) => model === 'TelegramPresentation');
  await waitFor(() => expect(subscribeToModel).toHaveBeenCalledWith('TelegramPresentation', 'resident', telegramProps));
  const cleanup =
    subscribeToModel.mock.results[subscribeToModel.mock.calls.findIndex(([model]) => model === 'TelegramPresentation')]
      .value;
  await view.rerender({
    ...props,
    agent: { ...props.agent, name: 'Renamed' },
    telegram_configuration: { ...props.telegram_configuration },
    telegram_subscriber_count: 3,
  });
  expect(calls()).toHaveLength(1);
  expect(cleanup).not.toHaveBeenCalled();
  await view.rerender({ ...props, agent: { ...props.agent, id: 'replacement' } });
  await waitFor(() => expect(calls()).toHaveLength(2));
  expect(calls()[1]).toEqual(['TelegramPresentation', 'replacement', telegramProps]);
  expect(cleanup).toHaveBeenCalledOnce();
  expect(subscribeToModel.mock.calls.every(([, , mapped]) => !mapped.includes('telegram_deep_link'))).toBe(true);
  view.unmount();
  expect(subscribeToModel.mock.results.at(-1).value).toHaveBeenCalledOnce();
});

test('incoming configuration overrides the stale agent summary and updates open settings without replacing its drafts', async () => {
  const view = render(EditResident, props);
  expect(screen.getByText('Connected')).toBeInTheDocument();
  await fireEvent.click(
    screen.getAllByRole('button', { name: 'Settings', exact: true }).find((button) => !button.closest('nav'))
  );
  expect(screen.getByText('@incoming_bot')).toBeInTheDocument();
  expect(screen.getByText('2 subscribers connected')).toBeInTheDocument();
  const token = screen.getByLabelText('Bot token');
  const username = screen.getByLabelText('Bot username');
  await fireEvent.input(token, { target: { value: 'synthetic-draft-token' } });
  await fireEvent.input(username, { target: { value: 'draft_username' } });
  await view.rerender({
    ...props,
    telegram_configuration: { configured: true, username: 'new_incoming_bot' },
    telegram_subscriber_count: 5,
  });
  expect(screen.getByText('@new_incoming_bot')).toBeInTheDocument();
  expect(screen.queryByText('@incoming_bot')).not.toBeInTheDocument();
  expect(screen.getByText('5 subscribers connected')).toBeInTheDocument();
  expect(screen.getByLabelText('Bot token')).toBe(token);
  expect(screen.getByLabelText('Bot username')).toBe(username);
  expect(token).toHaveValue('synthetic-draft-token');
  expect(username).toHaveValue('draft_username');
  await view.rerender({
    ...props,
    telegram_configuration: { configured: false, username: null },
    telegram_subscriber_count: 0,
  });
  expect(screen.getByText('Create a Telegram bot')).toBeInTheDocument();
  expect(screen.getByLabelText('Bot token')).toBe(token);
  expect(token).toHaveValue('synthetic-draft-token');
  expect(username).toHaveValue('draft_username');
  expect(router.reload).not.toHaveBeenCalled();
});
