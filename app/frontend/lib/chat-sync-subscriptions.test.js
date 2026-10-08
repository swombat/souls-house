import { describe, expect, test } from 'vitest';
import { buildChatSubscriptions, chatSyncSignature } from './chat-sync-subscriptions';

describe('chat sync subscriptions', () => {
  test('leaves the account subscription to the sidebar when no chat is open', () => {
    expect(buildChatSubscriptions({ account: { id: 12 }, chat: null })).toEqual({});
  });

  test('subscribes to chat messages and active whiteboard when present', () => {
    expect(
      buildChatSubscriptions({
        account: { id: 12 },
        chat: { id: 34, active_whiteboard: { id: 56 } },
      })
    ).toEqual({
      'Chat:34': ['chat', 'messages', 'runtime_interactions', 'cost_breakdown', 'agents'],
      'Chat:34:messages': 'messages',
      'Whiteboard:56': ['chat', 'messages'],
    });
  });

  test('new messages do not reconnect unchanged channels', () => {
    const context = { account: { id: 12 }, chat: { id: 34 } };
    expect(chatSyncSignature({ ...context, recentMessages: [{ id: 1 }] })).toBe(
      chatSyncSignature({ ...context, recentMessages: [{ id: 1 }, { id: 2 }] })
    );
  });

  test('account, chat and whiteboard identity changes reconnect channels', () => {
    const context = { account: { id: 12 }, chat: { id: 34 } };
    const initial = chatSyncSignature(context);
    expect(chatSyncSignature({ ...context, account: { id: 13 } })).not.toBe(initial);
    expect(chatSyncSignature({ ...context, chat: { id: 35 } })).not.toBe(initial);
    expect(chatSyncSignature({ ...context, chat: null })).not.toBe(initial);
    const withBoard = { ...context, chat: { id: 34, active_whiteboard: { id: 56 } } };
    expect(chatSyncSignature(withBoard)).not.toBe(initial);
    expect(chatSyncSignature({ ...context, chat: { id: 34, active_whiteboard: { id: 57 } } })).not.toBe(
      chatSyncSignature(withBoard)
    );
  });
});
