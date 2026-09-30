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
      'Chat:34': ['chat', 'messages', 'runtime_interactions', 'cost_breakdown'],
      'Chat:34:messages': 'messages',
      'Whiteboard:56': ['chat', 'messages'],
    });
  });

  test('signatures change when the selected chat or recent message ids change', () => {
    expect(chatSyncSignature({ account: { id: 12 }, chat: { id: 34 }, recentMessages: [{ id: 1 }, { id: 2 }] })).toBe(
      '12|34|1:2'
    );
    expect(chatSyncSignature({ account: { id: 12 }, chat: null, recentMessages: [] })).toBe('12|none|');
  });
});
