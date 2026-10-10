import { combinePaginatedMessages } from './chat-pagination-state';

export function patchMessageInCollections({ recentMessages = [], olderMessages = [], messageId, patch = {} }) {
  return {
    recentMessages: recentMessages.map((message) => (message.id === messageId ? { ...message, ...patch } : message)),
    olderMessages: olderMessages.map((message) => (message.id === messageId ? { ...message, ...patch } : message)),
  };
}

export function removeMessageFromCollections({ recentMessages = [], olderMessages = [], messageId }) {
  const all = combinePaginatedMessages(olderMessages, recentMessages).sort(
    (a, b) => new Date(a.created_at) - new Date(b.created_at)
  );
  const previous = all[all.findIndex((message) => message.id === messageId) - 1];
  const remove = (messages) =>
    messages
      .filter((message) => message.id !== messageId)
      .map((message) =>
        previous?.role === 'assistant' &&
        previous.agent_id &&
        previous.runtime_interaction_id &&
        message.id === previous.id
          ? { ...message, progress_break_after: true }
          : message
      );
  return { recentMessages: remove(recentMessages), olderMessages: remove(olderMessages) };
}

export function appendMessageIfMissing(messages = [], message) {
  if (!message?.id) return messages;
  if (messages.some((existingMessage) => existingMessage.id === message.id)) return messages;

  return [...messages, message];
}

// Handoff receipts, newest state wins. The ledger keeps the newest receipts
// seen per message (from a cable patch or a catch-up), by the version the
// server stamps on every copy, so a page fetch or reload that serialized an
// older state never puts it back.
export function recordReceipts(ledger, messageId, receipts, version) {
  if (!messageId || !Number.isFinite(version)) return false;
  const known = ledger.get(messageId);
  if (known && known.version >= version) return false;
  ledger.set(messageId, { receipts: receipts || [], version });
  return true;
}

// Every copy from the server is evidence too: remember its receipts if they
// are the newest seen, then bring every copy up to the newest. A fresh fetch
// therefore raises the floor, and a staler copy landing after it cannot
// revert what is shown.
export function applyReceiptLedger(messages = [], ledger) {
  for (const message of messages) {
    if (message.handoff_receipts_version > 0) {
      recordReceipts(ledger, message.id, message.handoff_receipts, message.handoff_receipts_version);
    }
  }
  if (!ledger?.size) return messages;
  let changed = false;
  const result = messages.map((message) => {
    const known = ledger.get(message.id);
    if (!known || known.version <= (message.handoff_receipts_version || 0)) return message;
    changed = true;
    return { ...message, handoff_receipts: known.receipts, handoff_receipts_version: known.version };
  });
  return changed ? result : messages;
}

// The older loaded messages whose receipts could still move, in batches of
// at most `size`: a room page asks for each batch once after its cable
// reconnects. Every such message is asked about; no request is unbounded.
export function receiptCatchUpBatches(messages = [], size = 50) {
  const ids = messages
    .filter((message) => (message.handoff_receipts || []).some((receipt) => receipt.state !== 'delivered'))
    .map((message) => message.id);
  const batches = [];
  for (let i = 0; i < ids.length; i += size) batches.push(ids.slice(i, i + size));
  return batches;
}
