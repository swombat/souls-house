import { render, screen } from '@testing-library/svelte';
import TelegramGroup from './telegram_group.svelte';

// The group page says what the house keeps from a group (#646 widened it to
// every message the bot receives) and marks each kept row: addressed to the
// resident, the conversation around it, or the resident's own reply.
const agent = { id: 'resident', name: 'Alanis', bot_username: 'alanis_bot' };
const group = { id: 'g1', title: 'MGL', allowed: true, removed: false };
const messages = [
  {
    id: 'm1',
    role: 'user',
    sender_name: 'Pepe',
    text: 'Morning all',
    sent_at: '2026-10-30T07:00:00Z',
    addressed: false,
  },
  { id: 'm2', role: 'user', sender_name: 'Pepe', text: 'Alanis?', sent_at: '2026-10-30T07:01:00Z', addressed: true },
  {
    id: 'm3',
    role: 'assistant',
    sender_name: 'Alanis',
    text: 'Here.',
    sent_at: '2026-10-30T07:02:00Z',
    addressed: false,
  },
];

test('says every message the bot receives is kept, and labels addressed, context and reply rows', () => {
  render(TelegramGroup, { agent, group, messages, privacy_mode_on: false, settings_path: '/settings' });

  expect(screen.getByTestId('telegram-group-state')).toHaveTextContent(
    'answers here when a person @mentions it, replies to it, or writes its name'
  );
  expect(screen.getByTestId('telegram-group-kept')).toHaveTextContent(
    'every message the bot receives from it is copied here'
  );
  expect(screen.getByTestId('telegram-group-kept')).not.toHaveTextContent('Only the messages that mentioned');
  expect(screen.getAllByTestId('telegram-group-message-label').map((node) => node.textContent)).toEqual([
    'context',
    'addressed to Alanis',
    'reply',
  ]);
  expect(screen.queryByTestId('telegram-group-privacy')).toBeNull();
});

test('with privacy mode on, says unaddressed conversation may be missing, without claiming nothing else arrives', () => {
  render(TelegramGroup, { agent, group, messages, privacy_mode_on: true, settings_path: '/settings' });

  const note = screen.getByTestId('telegram-group-privacy');
  expect(note).toHaveTextContent('privacy mode is on for @alanis_bot');
  expect(note).toHaveTextContent('unless the bot is an admin of the group');
  expect(note).toHaveTextContent('ordinary unaddressed conversation may be missing');
  expect(note).not.toHaveTextContent('only');
  expect(note).not.toHaveTextContent('never');
});

test('the group state distinguishes bot answers off, any bot, and selected bot usernames', async () => {
  const props = { agent, group, messages: [], settings_path: '/settings' };
  const view = render(TelegramGroup, props);
  expect(screen.getByTestId('telegram-group-state')).toHaveTextContent('does not answer other bots');
  await view.rerender({ ...props, group: { ...group, answers_bots: true, answer_bot_usernames: [] } });
  expect(screen.getByTestId('telegram-group-state')).toHaveTextContent('answers any other bot');
  expect(screen.getByTestId('telegram-group-state')).toHaveTextContent('never just write its name');
  expect(screen.getByTestId('telegram-group-state')).toHaveTextContent('at most 3 bot-triggered turns');
  await view.rerender({ ...props, group: { ...group, answers_bots: true, answer_bot_usernames: ['other_bot'] } });
  expect(screen.getByTestId('telegram-group-state')).toHaveTextContent('answers @other_bot');
  expect(screen.getByTestId('telegram-group-state')).not.toHaveTextContent('any other bot');
});

test('bot-addressed rows use the same addressed label as people, suppressed rows remain context', () => {
  render(TelegramGroup, {
    agent,
    group,
    settings_path: '/settings',
    messages: [
      { ...messages[0], sender_name: 'Other Bot', sender_username: 'other_bot', addressed: true },
      { ...messages[1], sender_name: 'Other Bot', sender_username: 'other_bot', addressed: false },
    ],
  });
  expect(screen.getAllByTestId('telegram-group-message-label').map((node) => node.textContent)).toEqual([
    'addressed to Alanis',
    'context',
  ]);
});

test('an off group never claims to answer bots even if its bot setting is on', () => {
  render(TelegramGroup, { agent, group: { ...group, allowed: false, answers_bots: true }, settings_path: '/settings' });
  expect(screen.getByTestId('telegram-group-state')).toHaveTextContent('does not read or keep anything');
  expect(screen.getByTestId('telegram-group-state')).not.toHaveTextContent('answers any other bot');
});
