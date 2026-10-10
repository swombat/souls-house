import { onDestroy, tick, untrack } from 'svelte';
import { accountChatMessagesPath } from '@/routes';
import {
  combinePaginatedMessages,
  prependOlderMessages,
  preserveDisplacedRecentMessages,
  shouldLoadMoreMessages,
} from './chat-pagination-state';
import {
  appendMessageIfMissing,
  applyReceiptLedger,
  patchMessageInCollections,
  receiptCatchUpIds,
  recordReceipts,
  removeMessageFromCollections,
} from './chat-message-collections';
import * as logging from './logging';
import { pinConversationEntry } from './chat-entry-scroll';

// The Inertia window and paginated history have one reconciliation owner.
export function createChatHistory(context) {
  let older = $state([]);
  let hasMore = $state(false);
  let oldestId = $state(null);
  let loading = $state(false);
  let container = $state();
  let previousRecent = [];
  let chatId;
  let request;
  let releaseEntry;
  // The newest handoff receipts seen per message, by version (see
  // recordReceipts): applied to every copy that arrives afterwards.
  let receiptLedger = new Map();
  const messages = $derived(combinePaginatedMessages(older, context().recent));

  $effect(() => {
    const current = context();
    const id = current.chat.id;
    const recent = current.recent;
    const serverHasMore = current.hasMore;
    const serverOldestId = current.oldestId;
    untrack(() => {
      if (id !== chatId) {
        request?.abort();
        request = null;
        loading = false;
        chatId = id;
        older = [];
        previousRecent = [];
        receiptLedger = new Map();
      } else {
        older = preserveDisplacedRecentMessages({
          olderMessages: older,
          previousRecentMessages: previousRecent,
          recentMessages: recent,
        });
      }
      // A reload serialized before a receipt moved must not put it back.
      const reconciled = applyReceiptLedger(recent, receiptLedger);
      if (reconciled !== recent) current.setRecent(reconciled);
      previousRecent = reconciled;
      if (older.length === 0) {
        hasMore = serverHasMore;
        oldestId = serverOldestId;
      }
    });
  });

  const entryChatId = $derived(context().chat.id);

  // Inertia can reuse this page for another chat without mounting it again.
  $effect(() => {
    const id = entryChatId;
    const element = container;
    if (!element) return;
    let cancelled = false;
    let release;
    tick().then(() => {
      if (!cancelled && context().chat.id === id) {
        release = pinConversationEntry(element);
        releaseEntry = release;
      }
    });
    return () => {
      cancelled = true;
      release?.();
    };
  });
  onDestroy(() => request?.abort());

  // A handoff receipt moved (cable.js). Remember it, then apply it wherever
  // the message is loaded: the recent window, or older history fetched by
  // scrolling, which a reload of the recent window never reaches. A copy
  // still in flight (a page fetch, an Inertia reload) is reconciled against
  // the same memory when it lands.
  function applyReceipts() {
    older = applyReceiptLedger(older, receiptLedger);
    const recent = context().recent;
    const reconciled = applyReceiptLedger(recent, receiptLedger);
    if (reconciled !== recent) context().setRecent(reconciled);
  }

  $effect(() => {
    const onReceipts = (event) => {
      const {
        chat_id: id,
        message_id: messageId,
        handoff_receipts: receipts,
        handoff_receipts_version: version,
      } = event.detail || {};
      if (id !== context().chat.id) return;
      if (recordReceipts(receiptLedger, messageId, receipts, version)) applyReceipts();
    };
    // After a reconnect the recent window reloads by itself; catch up the
    // receipts of the older messages already shown, a bounded set, once.
    const onReconnected = async (event) => {
      const current = context();
      if (event.detail?.id !== current.chat.id) return;
      const ids = receiptCatchUpIds(older);
      if (ids.length === 0) return;
      try {
        const response = await fetch(
          accountChatMessagesPath(current.account.id, current.chat.id, { receipts_for: ids.join(',') }),
          { headers: { Accept: 'application/json' } }
        );
        if (!response.ok || context().chat.id !== current.chat.id) return;
        const { receipts = {} } = await response.json();
        let recorded = false;
        for (const [messageId, entry] of Object.entries(receipts)) {
          recorded =
            recordReceipts(receiptLedger, messageId, entry.handoff_receipts, entry.handoff_receipts_version) ||
            recorded;
        }
        if (recorded) applyReceipts();
      } catch (error) {
        logging.error('Failed to catch up handoff receipts:', error);
      }
    };
    window.addEventListener('handoff-receipts', onReceipts);
    window.addEventListener('chat-sync-connected', onReconnected);
    return () => {
      window.removeEventListener('handoff-receipts', onReceipts);
      window.removeEventListener('chat-sync-connected', onReconnected);
    };
  });

  function scrollToBottom() {
    releaseEntry?.();
    tick().then(() => {
      container?.scrollTo({ top: container.scrollHeight, behavior: 'smooth' });
    });
  }

  async function loadMore() {
    if (loading || !hasMore || !oldestId || !container) return;
    const current = context();
    const id = current.chat.id;
    const element = container;
    const height = element.scrollHeight;
    const controller = new AbortController();
    request = controller;
    loading = true;
    try {
      const response = await fetch(accountChatMessagesPath(current.account.id, id, { before_id: oldestId }), {
        signal: controller.signal,
        headers: { Accept: 'application/json' },
      });
      if (!response.ok) return;
      const data = await response.json();
      if (controller.signal.aborted || context().chat.id !== id) return;
      const result = prependOlderMessages({
        olderMessages: older,
        newMessages: applyReceiptLedger(data.messages, receiptLedger),
        hasMore: data.has_more,
        oldestId: data.oldest_id,
      });
      older = result.olderMessages;
      hasMore = result.hasMore;
      oldestId = result.oldestId;
      await tick();
      if (!controller.signal.aborted && context().chat.id === id && element === container) {
        element.scrollTop += element.scrollHeight - height;
      }
    } catch (error) {
      if (error.name !== 'AbortError') logging.error('Failed to load more messages:', error);
    } finally {
      if (request === controller) {
        request = null;
        loading = false;
      }
    }
  }

  function handleScroll() {
    if (
      container &&
      container.scrollTop + container.clientHeight < container.scrollHeight - 1 &&
      shouldLoadMoreMessages({ scrollTop: container.scrollTop, hasMore, loadingMore: loading, oldestId })
    ) {
      loadMore();
    }
  }

  function update(messageId, patch) {
    const result = patchMessageInCollections({
      recentMessages: context().recent,
      olderMessages: older,
      messageId,
      patch,
    });
    context().setRecent(result.recentMessages);
    older = result.olderMessages;
  }

  function remove(messageId) {
    previousRecent = previousRecent.filter((message) => message.id !== messageId);
    const result = removeMessageFromCollections({ recentMessages: context().recent, olderMessages: older, messageId });
    context().setRecent(result.recentMessages);
    older = result.olderMessages;
  }

  return {
    get messages() {
      return messages;
    },
    get loading() {
      return loading;
    },
    get hasMore() {
      return hasMore;
    },
    get oldestId() {
      return oldestId;
    },
    get container() {
      return container;
    },
    set container(value) {
      container = value;
    },
    loadMore,
    handleScroll,
    update,
    remove,
    scrollToBottom,
    append(message) {
      context().setRecent(appendMessageIfMissing(context().recent, message));
    },
  };
}
