import { fireEvent, render, screen } from '@testing-library/svelte';
import { writable } from 'svelte/store';
import { vi } from 'vitest';

const patch = vi.fn();
vi.mock('@inertiajs/svelte', async () => {
  const original = await vi.importActual('@inertiajs/svelte');
  return { ...original, router: { ...original.router, patch: (...args) => patch(...args), reload: vi.fn() } };
});

const { default: TelegramSettings } = await import('./telegram-settings.svelte');

const group = (overrides = {}) => ({
  id: 'g1',
  title: 'MGL',
  allowed: false,
  removed: false,
  allowed_by: null,
  message_count: 0,
  path: '/accounts/home/agents/resident/telegram_groups/g1',
  ...overrides,
});

function props(overrides = {}) {
  return {
    agent: { id: 'resident', name: 'Alanis', telegram_configured: true, telegram_bot_username: 'alanis_bot' },
    accountId: 'home',
    form: writable({ agent: { telegram_bot_username: 'alanis_bot', telegram_bot_token: '' }, processing: false }),
    telegramConfiguration: { configured: true, username: 'alanis_bot' },
    telegramSubscriberCount: 0,
    telegramGroups: [],
    canManageTelegramGroups: true,
    ...overrides,
  };
}

beforeEach(() => patch.mockReset());

test('says who spends a turn, and how a group appears, before any group exists', () => {
  render(TelegramSettings, props());
  expect(screen.getByText(/spends a turn on this account's plan/)).toBeInTheDocument();
  expect(screen.getByTestId('telegram-groups-empty')).toHaveTextContent('switched off');
});

test('an owner switches a group on with one PATCH to that group', async () => {
  render(TelegramSettings, props({ telegramGroups: [group()] }));
  expect(screen.getByText(/nothing from this group is read or kept/)).toBeInTheDocument();
  await fireEvent.click(screen.getByRole('switch', { name: 'Allow Alanis in MGL' }));
  expect(patch).toHaveBeenCalledOnce();
  expect(patch.mock.calls[0][0]).toBe('/accounts/home/agents/resident/telegram_groups/g1');
  expect(patch.mock.calls[0][1]).toEqual({ allowed: true });
});

test('a member who is not an owner sees the state but no switch', () => {
  render(TelegramSettings, props({ telegramGroups: [group({ allowed: true })], canManageTelegramGroups: false }));
  expect(screen.queryByRole('switch')).not.toBeInTheDocument();
  expect(screen.getByText('Only an owner of this account can allow a group.')).toBeInTheDocument();
});

test('a group the bot has left cannot be switched on', () => {
  render(TelegramSettings, props({ telegramGroups: [group({ removed: true })] }));
  expect(screen.getByRole('switch', { name: 'Allow Alanis in MGL' })).toBeDisabled();
  expect(screen.getByText('The bot is no longer in this group.')).toBeInTheDocument();
});
