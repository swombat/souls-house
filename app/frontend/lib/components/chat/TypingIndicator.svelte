<script>
  // "Anna is typing…" for the other people in this conversation, and your own typing and
  // dictation announced to them (TypingChannel; people only, nothing stored).
  import { onDestroy, untrack } from 'svelte';
  import { cableConsumer } from '$lib/cable';
  import { TypingPresence, cableTypingSubscriber, SEND_EVERY_MS } from '$lib/typing-presence';

  let { chatId, userId, content = '', dictating = false } = $props();

  let line = $state('');
  const presence = new TypingPresence({
    selfUserId: userId,
    subscribe: cableTypingSubscriber(cableConsumer(), chatId),
    onchange: (next) => (line = next),
  });

  // Only a change is typing: a draft restored on load is not. Emptied (sent, or cleared)
  // is a stop.
  let lastContent = untrack(() => content);
  $effect(() => {
    const text = content;
    if (text === lastContent) return;
    lastContent = text;
    if (!untrack(() => dictating)) presence.set(text.trim() ? 'typing' : 'idle');
  });

  // Recording makes no keystrokes, so keep the others' line up with a heartbeat until it ends.
  let wasDictating = false;
  let heartbeat = null;
  $effect(() => {
    const active = dictating;
    clearInterval(heartbeat);
    heartbeat = null;
    if (active) {
      presence.set('dictating');
      heartbeat = setInterval(() => presence.set('dictating'), SEND_EVERY_MS);
    } else if (wasDictating) {
      presence.set('idle');
    }
    wasDictating = active;
  });

  onDestroy(() => {
    clearInterval(heartbeat);
    presence.dispose();
  });
</script>

{#if line}
  <p class="mb-1.5 text-xs italic text-muted-foreground" aria-live="polite" data-testid="typing-indicator">{line}</p>
{/if}
