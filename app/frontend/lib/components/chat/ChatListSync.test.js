import { render } from '@testing-library/svelte';
import { expect, test, vi } from 'vitest';
import ChatList from '../../../pages/chats/ChatList.svelte';

const { subscribe } = vi.hoisted(() => ({ subscribe: vi.fn(() => vi.fn()) }));
vi.mock('$lib/cable', () => ({ subscribeToModel: subscribe }));

test('the sidebar subscribes without an open chat and cleans up when switching accounts or unmounting', async () => {
  const { rerender, unmount } = render(ChatList, { accountId: 'first', chats: [] });
  expect(subscribe).toHaveBeenLastCalledWith('Account', 'first', ['chats', 'visual_tags']);
  const stopFirst = subscribe.mock.results[0].value;
  await rerender({ accountId: 'second', chats: [] });
  expect(stopFirst).toHaveBeenCalledOnce();
  expect(subscribe).toHaveBeenLastCalledWith('Account', 'second', ['chats', 'visual_tags']);
  const stopSecond = subscribe.mock.results.at(-1).value;
  unmount();
  expect(stopSecond).toHaveBeenCalledOnce();
});
