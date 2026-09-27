import { describe, expect, test } from 'vitest';
import {
  appendMessageIfMissing,
  patchMessageInCollections,
  removeMessageFromCollections,
} from './chat-message-collections';

describe('chat message collections', () => {
  test('patches a message in both recent and older collections', () => {
    const result = patchMessageInCollections({
      recentMessages: [{ id: 1, content: 'old' }],
      olderMessages: [
        { id: 1, content: 'older' },
        { id: 2, content: 'untouched' },
      ],
      messageId: 1,
      patch: { content: 'new', editable: false },
    });

    expect(result.recentMessages).toEqual([{ id: 1, content: 'new', editable: false }]);
    expect(result.olderMessages).toEqual([
      { id: 1, content: 'new', editable: false },
      { id: 2, content: 'untouched' },
    ]);
  });

  test('removes a message from both recent and older collections', () => {
    const result = removeMessageFromCollections({
      recentMessages: [{ id: 1 }, { id: 2 }],
      olderMessages: [{ id: 2 }, { id: 3 }],
      messageId: 2,
    });

    expect(result.recentMessages).toEqual([{ id: 1 }]);
    expect(result.olderMessages).toEqual([{ id: 3 }]);
  });

  test('appends only messages with new ids', () => {
    const messages = [{ id: 1, content: 'existing' }];
    const newMessage = { id: 2, content: 'new' };

    expect(appendMessageIfMissing(messages, null)).toBe(messages);
    expect(appendMessageIfMissing(messages, { id: 1, content: 'duplicate' })).toBe(messages);
    expect(appendMessageIfMissing(messages, newMessage)).toEqual([...messages, newMessage]);
  });
});

test('deleting a loaded-page interruption preserves the preceding progress boundary immediately', () => {
  const result = removeMessageFromCollections({
    olderMessages: [{ id: 1, progress_message: true }],
    recentMessages: [
      { id: 2, role: 'user' },
      { id: 3, progress_message: true },
    ],
    messageId: 2,
  });
  expect(result.olderMessages[0].progress_break_after).toBe(true);
  expect(result.recentMessages).toEqual([{ id: 3, progress_message: true }]);
});

test('deleting a late arrival marks its chronological predecessor locally', () => {
  const result = removeMessageFromCollections({
    recentMessages: [
      { id: 1, progress_message: true, created_at: '2026-09-27T08:00:00Z' },
      { id: 3, progress_message: true, created_at: '2026-09-27T08:02:00Z' },
      { id: 2, role: 'user', created_at: '2026-09-27T08:01:00Z' },
    ],
    messageId: 2,
  });
  expect(result.recentMessages[0].progress_break_after).toBe(true);
  expect(result.recentMessages[1].progress_break_after).toBeUndefined();
});
