import { describe, expect, test } from 'vitest';
import {
  combinePaginatedMessages,
  prependOlderMessages,
  preserveDisplacedRecentMessages,
  shouldLoadMoreMessages,
} from './chat-pagination-state';

describe('chat pagination state', () => {
  test('combines older and recent messages while preserving the recent copy of duplicates', () => {
    const olderMessages = [
      { id: 1, content: 'oldest' },
      { id: 2, content: 'older copy' },
    ];
    const recentMessages = [
      { id: 2, content: 'recent copy' },
      { id: 3, content: 'newest' },
    ];

    expect(combinePaginatedMessages(olderMessages, recentMessages)).toEqual([
      { id: 1, content: 'oldest' },
      { id: 2, content: 'recent copy' },
      { id: 3, content: 'newest' },
    ]);
  });

  test('loads more only near the top when more messages are available and idle', () => {
    expect(shouldLoadMoreMessages({ scrollTop: 199, hasMore: true, loadingMore: false, oldestId: 123 })).toBe(true);
    expect(shouldLoadMoreMessages({ scrollTop: 200, hasMore: true, loadingMore: false, oldestId: 123 })).toBe(false);
    expect(shouldLoadMoreMessages({ scrollTop: 10, hasMore: false, loadingMore: false, oldestId: 123 })).toBe(false);
    expect(shouldLoadMoreMessages({ scrollTop: 10, hasMore: true, loadingMore: true, oldestId: 123 })).toBe(false);
    expect(shouldLoadMoreMessages({ scrollTop: 10, hasMore: true, loadingMore: false, oldestId: null })).toBe(false);
  });

  test('prepends fetched messages and carries pagination metadata forward', () => {
    expect(
      prependOlderMessages({
        olderMessages: [{ id: 3 }],
        newMessages: [{ id: 1 }, { id: 2 }],
        hasMore: true,
        oldestId: 1,
      })
    ).toEqual({
      olderMessages: [{ id: 1 }, { id: 2 }, { id: 3 }],
      hasMore: true,
      oldestId: 1,
    });
  });

  test('keeps messages displaced when the latest server window advances', () => {
    const olderMessages = [{ id: 1 }, { id: 2 }];
    const previousRecentMessages = [{ id: 3 }, { id: 4 }, { id: 5 }];
    const recentMessages = [{ id: 5 }, { id: 6 }, { id: 7 }];

    expect(
      preserveDisplacedRecentMessages({
        olderMessages,
        previousRecentMessages,
        recentMessages,
      })
    ).toEqual([{ id: 1 }, { id: 2 }, { id: 3 }, { id: 4 }]);
  });
});

test('does not resurrect a deleted interruption as paginated history', () => {
  expect(
    preserveDisplacedRecentMessages({
      olderMessages: [{ id: 1 }],
      previousRecentMessages: [{ id: 2 }, { id: 3 }, { id: 4 }],
      recentMessages: [{ id: 2 }, { id: 4 }],
    })
  ).toEqual([{ id: 1 }]);
});

test('keeps a completely displaced window but clears deleted empty history', () => {
  expect(
    preserveDisplacedRecentMessages({
      previousRecentMessages: [{ id: 1 }, { id: 2 }],
      recentMessages: [{ id: 3 }, { id: 4 }],
    })
  ).toEqual([{ id: 1 }, { id: 2 }]);
  expect(
    preserveDisplacedRecentMessages({
      olderMessages: [{ id: 1 }],
      previousRecentMessages: [{ id: 2 }],
      recentMessages: [],
    })
  ).toEqual([]);
});

test('preserves array identity when no pagination or deletion happened', () => {
  const olderMessages = [{ id: 1 }];
  const recentMessages = [{ id: 2 }];
  expect(
    preserveDisplacedRecentMessages({ olderMessages, previousRecentMessages: recentMessages, recentMessages })
  ).toBe(olderMessages);
  const empty = [];
  expect(
    preserveDisplacedRecentMessages({ olderMessages: empty, previousRecentMessages: [{ id: 2 }], recentMessages: [] })
  ).toBe(empty);
});
