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
  expect(
    screen.getByText('Only an owner of this account can allow a group or change bot answers.')
  ).toBeInTheDocument();
  expect(screen.queryByRole('textbox', { name: /Bot usernames/ })).not.toBeInTheDocument();
});

test('a group the bot has left cannot be switched on', () => {
  render(TelegramSettings, props({ telegramGroups: [group({ removed: true })] }));
  expect(screen.getByRole('switch', { name: 'Allow Alanis in MGL' })).toBeDisabled();
  expect(screen.getByText('The bot is no longer in this group.')).toBeInTheDocument();
});

test('a group switched off in settings says the switch, not a mention, turns it back on', () => {
  render(TelegramSettings, props({ telegramGroups: [group({ allowed_at: '2026-10-29T08:00:00Z' })] }));
  expect(screen.getByText(/switched off here/)).toBeInTheDocument();
  expect(screen.queryByText(/until an owner mentions/)).not.toBeInTheDocument();
});

test("says how to turn privacy mode off when Telegram withholds a group's untagged messages", () => {
  render(
    TelegramSettings,
    props({ telegramConfiguration: { configured: true, username: 'alanis_bot', reads_all_group_messages: false } })
  );
  expect(screen.getByTestId('telegram-groups-privacy')).toHaveTextContent('/setprivacy');
  expect(screen.getByTestId('telegram-groups-privacy')).toHaveTextContent('Unless the bot is a group admin');
  expect(screen.getByTestId('telegram-groups-privacy')).toHaveTextContent('mentions, replies and commands');
  expect(screen.getByTestId('telegram-groups-privacy')).toHaveTextContent(
    'ordinary unaddressed conversation may be missing'
  );
  expect(screen.getByTestId('telegram-groups-privacy')).not.toHaveTextContent('only');
});

test('says nothing about privacy mode when the bot reads the whole group, or before it is known', () => {
  render(
    TelegramSettings,
    props({ telegramConfiguration: { configured: true, username: 'alanis_bot', reads_all_group_messages: true } })
  );
  expect(screen.queryByTestId('telegram-groups-privacy')).toBeNull();
  render(TelegramSettings, props());
  expect(screen.queryByTestId('telegram-groups-privacy')).toBeNull();
});

test('bot answers default off and explain cost, three-turn cap, human reset and no bare-name wakes', () => {
  render(TelegramSettings, props({ telegramGroups: [group()] }));
  expect(screen.getByRole('switch', { name: 'Answer other bots in MGL' })).not.toBeChecked();
  const note = screen.getByTestId('telegram-bot-answer-cost');
  expect(note).toHaveTextContent("owner's allowance");
  expect(note).toHaveTextContent('At most 3 bot-triggered turns');
  expect(note).toHaveTextContent('any person in the group resets');
  expect(note).toHaveTextContent('bare name never wakes');
});

test('an owner changes bot answers independently of the group on/off state', async () => {
  render(TelegramSettings, props({ telegramGroups: [group({ allowed: true })] }));
  await fireEvent.click(screen.getByRole('switch', { name: 'Answer other bots in MGL' }));
  expect(patch).toHaveBeenCalledOnce();
  expect(patch.mock.calls[0][1]).toEqual({ answers_bots: true });
  expect(screen.getByRole('switch', { name: 'Answer other bots in MGL' })).toBeDisabled();
});

test('an owner edits a bot list while answers are off and clears it to allow any bot', async () => {
  render(TelegramSettings, props({ telegramGroups: [group({ answer_bot_usernames: ['old_bot'] })] }));
  const input = screen.getByRole('textbox', { name: 'Bot usernames for MGL' });
  expect(input).toHaveValue('old_bot');
  await fireEvent.input(input, { target: { value: '@Other_bot, second_bot' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Save bot list' }));
  expect(patch.mock.calls[0][1]).toEqual({ answer_bot_usernames: ['@Other_bot', 'second_bot'] });
  patch.mock.calls[0][2].onFinish();
  await fireEvent.input(input, { target: { value: '  ' } });
  await fireEvent.click(screen.getByRole('button', { name: 'Save bot list' }));
  expect(patch.mock.calls[1][1]).toEqual({ answer_bot_usernames: [] });
});

test('members see the bot state and list, but cannot edit either', () => {
  render(
    TelegramSettings,
    props({
      telegramGroups: [group({ allowed: true, answers_bots: true, answer_bot_usernames: ['other_bot'] })],
      canManageTelegramGroups: false,
    })
  );
  expect(screen.getByText('On')).toBeInTheDocument();
  expect(screen.getByText('Bots allowed: @other_bot.')).toBeInTheDocument();
  expect(screen.queryByRole('switch')).not.toBeInTheDocument();
});

test('an unsaved bot list survives an unrelated presentation update', async () => {
  const initial = props({ telegramGroups: [group({ answer_bot_usernames: ['old_bot'] })] });
  const view = render(TelegramSettings, initial);
  const input = screen.getByRole('textbox', { name: 'Bot usernames for MGL' });
  await fireEvent.input(input, { target: { value: 'unfinished_bot' } });
  await view.rerender({
    ...initial,
    telegramSubscriberCount: 5,
    telegramGroups: [group({ answer_bot_usernames: ['old_bot'], message_count: 2 })],
  });
  expect(input).toHaveValue('unfinished_bot');
});
