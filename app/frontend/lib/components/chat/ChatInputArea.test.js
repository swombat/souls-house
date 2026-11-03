import { fireEvent, render, screen } from '@testing-library/svelte';
import ChatInputArea from './ChatInputArea.svelte';

// The chat page passes agentIsResponding whenever any resident is running.
// It used to disable the whole trigger bar, which made the queued-wake
// button (#252) unreachable from the real page while the standalone bar
// tests passed. A busy resident stays askable from the page itself.
test('a resident already responding can still be asked from the chat page', () => {
  render(ChatInputArea, {
    chat: { id: 'chat', manual_responses: true, respondable: true },
    agents: [
      { id: 'busy', name: 'Busy' },
      { id: 'idle', name: 'Idle' },
    ],
    accountId: 'account',
    agentIsResponding: true,
    activeRuntimeAgentIds: ['busy'],
  });
  expect(screen.getByRole('button', { name: 'Busy' })).toBeEnabled();
  expect(screen.getByRole('button', { name: 'Idle' })).toBeEnabled();
  expect(screen.getByRole('button', { name: 'Ask All' })).toBeEnabled();
});

test('an unrespondable conversation still disables the bar', () => {
  render(ChatInputArea, {
    chat: { id: 'chat', manual_responses: true, respondable: false },
    agents: [{ id: 'one', name: 'One' }],
    accountId: 'account',
  });
  expect(screen.getByRole('button', { name: 'One' })).toBeDisabled();
});

// Voice mode (VoiceMode): an empty composer offers the wave button in place of
// Send when the account's mode is on; when it cannot start, a tap says why.
const chat = { id: 'chat', manual_responses: false, respondable: true };

test('without voice mode the empty composer shows Send', () => {
  render(ChatInputArea, {
    chat,
    accountId: 'account',
    voiceMode: { offered: false, available: false, reason: 'account_disabled' },
  });
  expect(screen.getByRole('button', { name: 'Send message' })).toBeDisabled();
  expect(screen.queryByTestId('voice-mode-button')).toBeNull();
});

test('with voice mode available the empty composer offers the wave button', () => {
  render(ChatInputArea, { chat, accountId: 'account', voiceMode: { offered: true, available: true, reason: null } });
  const wave = screen.getByRole('button', { name: 'Start voice mode' });
  expect(wave).toHaveAttribute('aria-disabled', 'false');
  expect(screen.queryByRole('button', { name: 'Send message' })).toBeNull();
});

test('offered without a key, the wave button explains itself when tapped instead of starting', async () => {
  render(ChatInputArea, {
    chat,
    accountId: 'account',
    voiceMode: { offered: true, available: false, reason: 'no_transcription_key' },
  });
  const wave = screen.getByRole('button', { name: 'Start voice mode' });
  expect(wave).toHaveAttribute('aria-disabled', 'true');
  await fireEvent.click(wave);
  expect(screen.getByTestId('voice-mode-notice')).toHaveTextContent('OpenAI API key');
  expect(screen.queryByTestId('voice-mode-panel')).toBeNull();
});

// Arriving from New Chat's wave (voice-mode-start): voice mode opens once, on
// the conversation page that loads next, and never on a plain visit.
import { armVoiceStart, takeVoiceStart } from '$lib/voice-mode-start';

test('a conversation reached from the New Chat wave opens voice mode', () => {
  armVoiceStart();
  render(ChatInputArea, { chat, accountId: 'account', voiceMode: { offered: true, available: true, reason: null } });
  expect(screen.getByTestId('voice-mode-panel')).toBeInTheDocument();
  expect(takeVoiceStart()).toBe(false);
});

test('a plain visit does not open voice mode', () => {
  render(ChatInputArea, { chat, accountId: 'account', voiceMode: { offered: true, available: true, reason: null } });
  expect(screen.queryByTestId('voice-mode-panel')).toBeNull();
});

test('the wave intent is spent even when the mode cannot start here', () => {
  armVoiceStart();
  render(ChatInputArea, {
    chat,
    accountId: 'account',
    voiceMode: { offered: true, available: false, reason: 'no_transcription_key' },
  });
  expect(screen.queryByTestId('voice-mode-panel')).toBeNull();
  expect(takeVoiceStart()).toBe(false);
});
