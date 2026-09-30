import { onMount, onDestroy } from 'svelte';
import { router } from '@inertiajs/svelte';
import { isChatResponseTimedOut, shouldShowSendingPlaceholder } from './chat-message-state';

export function createChatResponse(context) {
  let waiting = $state(false);
  let sentAt = $state(null);
  let now = $state(Date.now());
  let agentPrompt = $state(false);
  let refreshTimer;
  let promptTimer;
  let previousChatId;
  const placeholder = $derived(
    shouldShowSendingPlaceholder({
      chat: context().chat,
      messages: context().messages,
      waitingForResponse: waiting,
    })
  );
  const timedOut = $derived(
    isChatResponseTimedOut({
      chat: context().chat,
      messages: context().messages,
      waitingForResponse: waiting,
      messageSentAt: sentAt,
      currentTime: now,
    })
  );
  $effect(() => {
    const { chat, messages } = context();
    if (chat.id !== previousChatId) {
      previousChatId = chat.id;
      clearTimeout(refreshTimer);
      clearTimeout(promptTimer);
      agentPrompt = false;
      clearWaiting();
    } else if (messages.at(-1)?.role === 'assistant') {
      clearWaiting();
    }
  });
  onMount(() => {
    const interval = setInterval(() => (now = Date.now()), 5000);
    return () => clearInterval(interval);
  });
  onDestroy(() => {
    clearTimeout(refreshTimer);
    clearTimeout(promptTimer);
  });

  // One fallback read after a trigger, not a legacy token-stream polling loop.
  function refreshMessages() {
    clearTimeout(refreshTimer);
    const chatId = context().chat.id;
    refreshTimer = setTimeout(() => {
      if (context().chat.id === chatId) router.reload({ only: ['messages'], preserveScroll: true });
    }, 5000);
  }
  function clearWaiting() {
    waiting = false;
    sentAt = null;
  }
  return {
    get placeholder() {
      return placeholder;
    },
    get timedOut() {
      return timedOut;
    },
    get agentPrompt() {
      return agentPrompt;
    },
    refreshMessages,
    clearWaiting,
    wait() {
      if (!context().chat.manual_responses) {
        waiting = true;
        sentAt = Date.now();
      }
    },
    prompt() {
      clearTimeout(promptTimer);
      agentPrompt = true;
      promptTimer = setTimeout(() => (agentPrompt = false), 3000);
    },
  };
}
