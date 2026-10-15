import { beforeEach, expect, test, vi } from 'vitest';

const hooks = vi.hoisted(() => ({ destroy: [] }));
const subscribe = vi.hoisted(() => vi.fn());
vi.mock('svelte', () => ({
  onMount: vi.fn(),
  onDestroy: (callback) => hooks.destroy.push(callback),
}));
vi.mock('./cable', () => ({ subscribeToModel: subscribe }));
import { createDynamicSync } from './use-sync';

beforeEach(() => {
  hooks.destroy = [];
  subscribe.mockReset();
  subscribe.mockImplementation(() => vi.fn());
});

test('fresh serialized subscriptions do not reconnect unchanged channels', () => {
  const update = createDynamicSync();
  update({ 'Account:one': ['chats', 'rooms'], 'ReplyAttention:me': 'reply_attention' });
  const unsubscribe = subscribe.mock.results.map(({ value }) => value);
  update({ 'ReplyAttention:me': ['reply_attention'], 'Account:one': ['rooms', 'chats'] });
  expect(subscribe).toHaveBeenCalledTimes(2);
  for (const callback of unsubscribe) expect(callback).not.toHaveBeenCalled();
  hooks.destroy[0]();
  for (const callback of unsubscribe) expect(callback).toHaveBeenCalledOnce();
});

test('channel or requested-prop changes reconnect; clearing and destruction clean up', () => {
  const update = createDynamicSync();
  update({ 'Account:one': 'chats' });
  const first = subscribe.mock.results[0].value;
  update({ 'Account:two': 'chats' });
  expect(first).toHaveBeenCalledOnce();
  expect(subscribe).toHaveBeenLastCalledWith('Account', 'two', ['chats']);
  const second = subscribe.mock.results[1].value;
  update({ 'Account:two': ['chats', 'rooms'] });
  expect(second).toHaveBeenCalledOnce();
  const third = subscribe.mock.results[2].value;
  update({});
  expect(third).toHaveBeenCalledOnce();
  update({});
  expect(subscribe).toHaveBeenCalledTimes(3);
  hooks.destroy[0]();
  expect(third).toHaveBeenCalledOnce();
});
