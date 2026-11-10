<script>
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import ParticipantAvatars from '$lib/components/chat/ParticipantAvatars.svelte';

  // The context and cost figures live in the View costs panel (ConversationCostDrawer);
  // the header keeps only who is in the conversation and the length warning.
  let { chat, agents = [], allMessages = [], tokenWarningLevel = 'none' } = $props();
</script>

<div class="text-sm text-muted-foreground flex items-center gap-2 flex-wrap">
  {#if chat?.manual_responses}
    <ParticipantAvatars {agents} messages={allMessages} />
  {:else}
    {chat?.model_label || chat?.model_id || 'Auto'}
  {/if}

  {#if tokenWarningLevel === 'amber'}
    <Badge
      variant="outline"
      class="bg-amber-100 text-amber-800 border-amber-300 dark:bg-amber-900/30 dark:text-amber-400 dark:border-amber-700">
      Long conversation
    </Badge>
  {:else if tokenWarningLevel === 'red'}
    <Badge
      variant="outline"
      class="bg-red-100 text-red-800 border-red-300 dark:bg-red-900/30 dark:text-red-400 dark:border-red-700">
      Very long
    </Badge>
  {:else if tokenWarningLevel === 'critical'}
    <Badge variant="destructive">Extremely long</Badge>
  {/if}
</div>
