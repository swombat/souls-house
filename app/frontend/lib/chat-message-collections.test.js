import { describe, expect, test } from 'vitest';
import {
  appendMessageIfMissing,
  applyReceiptLedger,
  patchMessageInCollections,
  receiptCatchUpBatches,
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
    expect(applyReceiptLedger([{ id: 'm3' }], new Map())).toEqual([{ id: 'm3' }]);
  });

  // Mira's third review: held v20, then a fetched delivered v30, then a stale
  // queued v25 must stay delivered.
  test('a fresh fetched copy raises the floor for copies that land after it', () => {
    const held = [{ recipient_id: 'mira', recipient_name: 'Mira', state: 'held' }];
    const ledger = new Map();
    recordReceipts(ledger, 'm1', held, 20);
    applyReceiptLedger([{ id: 'm1', handoff_receipts: delivered, handoff_receipts_version: 30 }], ledger);
    const after = applyReceiptLedger([{ id: 'm1', handoff_receipts: queued, handoff_receipts_version: 25 }], ledger);
    expect(after[0].handoff_receipts).toEqual(delivered);
    expect(after[0].handoff_receipts_version).toBe(30);
  });

  test('catches up every message whose receipts can still move, in bounded batches', () => {
    const messages = [
      { id: 'a', handoff_receipts: delivered },
      { id: 'b', handoff_receipts: queued },
      { id: 'c' },
      { id: 'd', handoff_receipts: [{ state: 'blocked' }] },
      { id: 'e', handoff_receipts: [{ state: 'held' }] },
    ];
    expect(receiptCatchUpBatches(messages)).toEqual([['b', 'd', 'e']]);
    expect(receiptCatchUpBatches(messages, 2)).toEqual([['b', 'd'], ['e']]);
    const many = Array.from({ length: 51 }, (_, i) => ({ id: `m${i}`, handoff_receipts: queued }));
    const batches = receiptCatchUpBatches(many);
    expect(batches.map((batch) => batch.length)).toEqual([50, 1]);
    expect(batches.flat()).toContain('m0');
  });
});
