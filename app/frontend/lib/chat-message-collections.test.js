import { describe, expect, test } from 'vitest';
import {
  appendMessageIfMissing,
  applyReceiptLedger,
  patchMessageInCollections,
  receiptCatchUpIds,
  recordReceipts,
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
    olderMessages: [{ id: 1, role: 'assistant', agent_id: 1, runtime_interaction_id: 10 }],
    recentMessages: [
      { id: 2, role: 'user' },
      { id: 3, role: 'assistant', agent_id: 1, runtime_interaction_id: 10 },
    ],
    messageId: 2,
  });
  expect(result.olderMessages[0].progress_break_after).toBe(true);
  expect(result.recentMessages).toEqual([{ id: 3, role: 'assistant', agent_id: 1, runtime_interaction_id: 10 }]);
});

test('deleting a late arrival marks its chronological predecessor locally', () => {
  const result = removeMessageFromCollections({
    recentMessages: [
      { id: 1, role: 'assistant', agent_id: 1, runtime_interaction_id: 10, created_at: '2026-09-27T08:00:00Z' },
      { id: 3, role: 'assistant', agent_id: 1, runtime_interaction_id: 10, created_at: '2026-09-27T08:02:00Z' },
      { id: 2, role: 'user', created_at: '2026-09-27T08:01:00Z' },
    ],
    messageId: 2,
  });
  expect(result.recentMessages[0].progress_break_after).toBe(true);
  expect(result.recentMessages[1].progress_break_after).toBeUndefined();
});

describe('handoff receipt ledger', () => {
  const queued = [{ recipient_id: 'mira', recipient_name: 'Mira', state: 'queued' }];
  const delivered = [{ recipient_id: 'mira', recipient_name: 'Mira', state: 'delivered' }];

  test('keeps only the newest receipts per message', () => {
    const ledger = new Map();
    expect(recordReceipts(ledger, 'm1', delivered, 20)).toBe(true);
    expect(recordReceipts(ledger, 'm1', queued, 10)).toBe(false);
    expect(recordReceipts(ledger, 'm1', queued, 20)).toBe(false);
    expect(recordReceipts(ledger, 'm1', undefined, Number.NaN)).toBe(false);
    expect(ledger.get('m1')).toEqual({ receipts: delivered, version: 20 });
  });

  test('a stale copy is corrected, a fresher one is kept, and nothing changes without cause', () => {
    const ledger = new Map([['m1', { receipts: delivered, version: 20 }]]);
    const stale = [{ id: 'm1', handoff_receipts: queued, handoff_receipts_version: 10 }, { id: 'm2' }];
    const fixed = applyReceiptLedger(stale, ledger);
    expect(fixed[0]).toEqual({ id: 'm1', handoff_receipts: delivered, handoff_receipts_version: 20 });
    expect(fixed[1]).toBe(stale[1]);

    const fresher = [{ id: 'm1', handoff_receipts: queued, handoff_receipts_version: 30 }];
    expect(applyReceiptLedger(fresher, ledger)).toBe(fresher);
    expect(applyReceiptLedger(stale, new Map())).toBe(stale);
  });

  test('catches up only messages whose receipts can still move, within a bound', () => {
    const messages = [
      { id: 'a', handoff_receipts: delivered },
      { id: 'b', handoff_receipts: queued },
      { id: 'c' },
      { id: 'd', handoff_receipts: [{ state: 'blocked' }] },
      { id: 'e', handoff_receipts: [{ state: 'held' }] },
    ];
    expect(receiptCatchUpIds(messages)).toEqual(['b', 'd', 'e']);
    expect(receiptCatchUpIds(messages, 2)).toEqual(['d', 'e']);
  });
});
