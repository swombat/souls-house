<script>
  import AgentTriggerBar from '$lib/components/chat/AgentTriggerBar.svelte';
  import MessageComposer from '$lib/components/chat/MessageComposer.svelte';
  import { page } from '@inertiajs/svelte';

  let {
    chat,
    agents = [],
    accountId,
    showUsage = false,
    agentIsResponding = false,
    activeRuntimeAgentIds = [],
    runtimeInteractions = [],
    responseMarker = null,
    fileUploadConfig = {},
    onAgentTrigger = () => {},
    onSent = () => {},
    onWaiting = () => {},
    onError = () => {},
    onAgentPrompt = () => {},
  } = $props();
</script>

{#if chat?.manual_responses && agents?.length > 0}
  <AgentTriggerBar
    {agents}
    {accountId}
    {showUsage}
    chatId={chat.id}
    disabled={agentIsResponding || !chat?.respondable}
    {activeRuntimeAgentIds}
    {runtimeInteractions}
    {responseMarker}
    onTrigger={onAgentTrigger} />
{/if}

{#if chat && !chat.respondable}
  <div
    class="border-t border-amber-500 bg-amber-50 dark:bg-amber-950/30 px-4 py-2 text-center text-amber-700 dark:text-amber-400 text-sm">
    {#if chat.discarded}
      This conversation has been deleted.
    {:else}
      This conversation has been archived.
    {/if}
  </div>
{/if}

{#key `${$page.props.user?.id}:${accountId}:${chat?.id}`}
  <MessageComposer
    userId={$page.props.user?.id}
    {accountId}
    chatId={chat?.id}
    disabled={!chat?.respondable}
    manualResponses={chat?.manual_responses}
    {fileUploadConfig}
    onsent={onSent}
    onwaiting={onWaiting}
    onerror={onError}
    onagentprompt={onAgentPrompt} />
{/key}
