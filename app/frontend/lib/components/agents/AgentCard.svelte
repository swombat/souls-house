<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Badge } from '$lib/components/shadcn/badge';
  import { PencilSimple, Trash, Copy } from 'phosphor-svelte';
  import { agentIconFor } from '$lib/agent-icons';
  import { editAccountAgentPath } from '@/routes';
  import AgentSubscriptionUsageSummary from '$lib/components/agents/AgentSubscriptionUsageSummary.svelte';

  let { agent, accountId, toolNameLookup = {}, onupgrade, ondelete } = $props();
  let IconComponent = $derived(agentIconFor(agent.icon));
</script>

<Card class="hover:border-primary/50 transition-colors">
  <CardHeader class="pb-3">
    <div class="flex items-start justify-between">
      <div class="flex items-center gap-3">
        <div
          class="p-2 rounded-lg {agent.colour
            ? `bg-${agent.colour}-100 dark:bg-${agent.colour}-900`
            : 'bg-primary/10'}">
          <IconComponent
            class="size-5 {agent.colour ? `text-${agent.colour}-700 dark:text-${agent.colour}-300` : 'text-primary'}"
            weight="duotone" />
        </div>
        <div>
          <CardTitle class="text-lg">{agent.name}</CardTitle>
          <div class="flex flex-wrap gap-1 mt-1">
            {#if !agent.active}
              <Badge variant="secondary">Inactive</Badge>
            {/if}
            {#if agent.paused}
              <Badge variant="outline" title="Excluded from cron sweeps. Manual triggers still work.">Paused</Badge>
            {/if}
          </div>
        </div>
      </div>
    </div>
  </CardHeader>
  <CardContent>
    <p class="text-sm text-muted-foreground line-clamp-2 mb-4 min-h-[2.5rem]">
      {agent.system_prompt || 'No system prompt defined'}
    </p>

    <div class="text-xs text-muted-foreground mb-2">
      <span class="font-medium">Model:</span>
      {agent.model_label || agent.model_id}
    </div>

    {#if agent.memory_token_summary}
      {@const mts = agent.memory_token_summary}
      <div class="text-xs text-muted-foreground mb-4 flex flex-wrap gap-x-3 gap-y-0.5">
        <span><span class="font-medium">Core:</span> {mts.core.toLocaleString()}t</span>
        <span><span class="font-medium">Journal:</span> {mts.active_journal.toLocaleString()}t</span>
        {#if mts.inactive_journal > 0}
          <span class="opacity-50">
            <span class="font-medium">Inactive:</span>
            {mts.inactive_journal.toLocaleString()}t
          </span>
        {/if}
      </div>
    {/if}

    {#if agent.provider_subscription?.auth_mode === 'oauth_account'}
      <AgentSubscriptionUsageSummary {accountId} agentId={agent.id} subscription={agent.provider_subscription} />
    {/if}

    {#if agent.enabled_tools?.length > 0}
      <div class="flex flex-wrap gap-1 mb-4">
        {#each agent.enabled_tools.slice(0, 3) as tool}
          <Badge variant="outline" class="text-xs">{toolNameLookup[tool] || tool}</Badge>
        {/each}
        {#if agent.enabled_tools.length > 3}
          <Badge variant="outline" class="text-xs">+{agent.enabled_tools.length - 3} more</Badge>
        {/if}
      </div>
    {/if}

    <div class="flex gap-2 pt-2 border-t">
      <a href={editAccountAgentPath(accountId, agent.id)} class="flex-1">
        <Button variant="outline" size="sm" class="w-full">
          <PencilSimple class="mr-1 size-4" />
          Edit
        </Button>
      </a>
      <Button
        variant="outline"
        size="sm"
        onclick={() => onupgrade?.(agent)}
        title="Upgrade this resident's model and preserve the current state as a predecessor for cross-version conversation">
        <Copy class="size-4" />
      </Button>
      <Button
        variant="outline"
        size="sm"
        onclick={() => ondelete?.(agent)}
        class="text-destructive hover:text-destructive">
        <Trash class="size-4" />
      </Button>
    </div>
  </CardContent>
</Card>
