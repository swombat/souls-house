import { fireEvent, render, screen } from '@testing-library/svelte';
import { afterEach, expect, test, vi } from 'vitest';
import { router } from '@inertiajs/svelte';
import ChatParticipants from './ChatParticipants.svelte';

vi.mock('@inertiajs/svelte', () => ({ router: { delete: vi.fn() } }));
vi.mock('@/routes', () => ({
  accountChatParticipantPath: (account, chat) => `/accounts/${account}/chats/${chat}/participant`,
}));

const props = {
  chat: { id: 'chat-1' },
  account: { id: 'account-1' },
  agents: [
    { id: 'agent-1', name: 'Mira', can_remove_from_chat: true },
    { id: 'agent-2', name: 'Lume', can_remove_from_chat: false },
  ],
};

afterEach(() => {
  vi.clearAllMocks();
  if (vi.isMockFunction(window.confirm)) window.confirm.mockRestore();
});

async function open() {
  await fireEvent.click(screen.getByRole('button', { name: 'Conversation residents' }));
}

test('only offers removal for seats the current person may remove', async () => {
  render(ChatParticipants, props);
  await open();
  expect(screen.getByRole('menuitem', { name: 'Remove Mira' })).toBeInTheDocument();
  expect(screen.queryByRole('menuitem', { name: 'Remove Lume' })).not.toBeInTheDocument();
  expect(screen.getByText(/A responding resident must finish/)).toBeInTheDocument();
});

test('does not show a management control without permission', () => {
  render(ChatParticipants, {
    ...props,
    agents: [{ id: 'agent-1', name: 'Mira', can_remove_from_chat: false }],
  });
  expect(screen.queryByRole('button', { name: 'Conversation residents' })).not.toBeInTheDocument();
});

test('confirmation explains preservation and account boundary; cancel does nothing', async () => {
  vi.spyOn(window, 'confirm').mockReturnValue(false);
  render(ChatParticipants, props);
  await open();
  await fireEvent.click(screen.getByRole('menuitem', { name: 'Remove Mira' }));
  expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('Past messages stay.'));
  expect(window.confirm).toHaveBeenCalledWith(expect.stringContaining('does not remove them from the account'));
  expect(router.delete).not.toHaveBeenCalled();
});

test('removal uses the seat endpoint, preserving scroll and exposing request failure', async () => {
  vi.spyOn(window, 'confirm').mockReturnValue(true);
  const onerror = vi.fn();
  render(ChatParticipants, { ...props, onerror });
  await open();
  await fireEvent.click(screen.getByRole('menuitem', { name: 'Remove Mira' }));
  expect(router.delete).toHaveBeenCalledWith('/accounts/account-1/chats/chat-1/participant', {
    data: { agent_id: 'agent-1' },
    preserveScroll: true,
    onError: expect.any(Function),
    onFinish: expect.any(Function),
  });
  const options = router.delete.mock.calls.at(-1)[1];
  options.onError();
  expect(onerror).toHaveBeenCalledWith(expect.stringContaining('Could not remove'));
  options.onFinish();
});
