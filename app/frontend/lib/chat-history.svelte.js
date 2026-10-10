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
  patchMessageInCollections,
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
      } else {
        older = preserveDisplacedRecentMessages({
          olderMessages: older,
          previousRecentMessages: previousRecent,
          recentMessages: recent,
        });
      }
      previousRecent = recent;
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

  // A handoff receipt moved (cable.js). Patch the message wherever it is
  // loaded: the recent window, or older history fetched by scrolling, which
  // a refresh of the recent window never reaches.
  $effect(() => {
    const onReceipts = (event) => {
      const { chat_id: id, message_id: messageId, handoff_receipts: receipts } = event.detail || {};
      if (!messageId || id !== context().chat.id) return;
      update(messageId, { handoff_receipts: receipts || [] });
    };
    window.addEventListener('handoff-receipts', onReceipts);
    return () => window.removeEventListener('handoff-receipts', onReceipts);
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
        newMessages: data.messages,
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
