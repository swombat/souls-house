<script>
  import { page } from '@inertiajs/svelte';
  import {
    conversationTitle,
    setConversationTitleAccount,
    watchConversationTitle,
  } from '$lib/conversation-titles.svelte.js';

  // token comes from conversationRefExtension; live is false while a message
  // is still streaming, so growing prefixes of an ID are not looked up.
  let { token, theme = {}, live = true } = $props();

  const accountId = $derived($page.props.account?.id ?? null);
  const enabled = $derived(live && accountId !== null);
  const title = $derived(enabled ? conversationTitle(token.id) : null);
  const href = $derived(
    accountId ? `/accounts/${encodeURIComponent(accountId)}/chats/${encodeURIComponent(token.id)}` : null
  );

  $effect(() => {
    if (!enabled) return;
    setConversationTitleAccount(accountId);
    return watchConversationTitle(token.id);
  });
</script>

<!-- No whitespace between tags below: it would render as a space before punctuation. -->
{#if title && href}<a
    class={theme.link?.base}
    {href}
    title={`Conversation ${token.id}`}
    data-conversation-ref={token.id}>{title}</a
  >{:else if token.form === 'code'}<code data-streamdown-codespan class={theme.codespan?.base}>{token.id}</code
  >{:else}{token.id}{/if}
