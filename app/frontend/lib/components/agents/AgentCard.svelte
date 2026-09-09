<script>
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Badge } from '$lib/components/shadcn/badge';
  import {
    PencilSimple,
    Trash,
    Copy,
    Graph,
    Notebook,
    HardDrive,
    Heart,
    TelegramLogo,
    GithubLogo,
    DropboxLogo,
    GoogleLogo,
    Circle,
    Plugs,
  } from 'phosphor-svelte';
  import { agentIconFor } from '$lib/agent-icons';
  import { editAccountAgentPath } from '@/routes';
  import AgentSubscriptionUsageSummary from '$lib/components/agents/AgentSubscriptionUsageSummary.svelte';

  import ResidentActivity from './ResidentActivity.svelte';
  const integrationIcons = {
    telegram: TelegramLogo,
    github: GithubLogo,
    dropbox: DropboxLogo,
    google_workspace: GoogleLogo,
    oura: Circle,
  };
  function diskSize(bytes) {
    if (bytes == null) return '—';
    if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(0)} KiB`;
    if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MiB`;
    return `${(bytes / 1024 ** 3).toFixed(1)} GiB`;
  }

  let { agent, accountId, onupgrade, ondisable } = $props();
  let heartbeatEnabled = $derived(agent.scheduled_wakes_enabled && agent.active && !agent.paused && !agent.deprecated);
  let IconComponent = $derived(agentIconFor(agent.icon));
</script>

<Card
  class="hover:border-primary/50 transition-colors {!agent.active || agent.deprecated ? 'grayscale opacity-60' : ''}">
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
          <p class="text-xs font-light text-muted-foreground mt-0.5">{agent.model_label || agent.model_id}</p>
          <div class="flex flex-wrap gap-1 mt-1">
            {#if agent.deprecated}
              <Badge variant="secondary" title="The inline runtime has been retired. History is preserved.">
                Deprecated · Unavailable
              </Badge>
            {/if}
            {#if !agent.active}
              <Badge variant="secondary">Disabled</Badge>
            {/if}
            {#if agent.paused && !agent.deprecated}
              <Badge variant="outline" title="Excluded from cron sweeps. Manual triggers still work.">Paused</Badge>
            {/if}
          </div>
        </div>
      </div>
    </div>
  </CardHeader>
  <CardContent>
    {#if !agent.deprecated}
      <div class="text-xs text-muted-foreground mb-4 flex flex-wrap gap-x-3 gap-y-0.5">
        <span
          class="inline-flex items-center gap-1"
          title="All nodes in this resident's private graph, including dormant nodes. Contents stay private.">
          <Graph class="size-4" aria-label="Mnemodyne nodes" />
          {(agent.mnemodyne_node_count ?? 0).toLocaleString()}
        </span>
        <span
          class="inline-flex items-center gap-1"
          title={agent.journal_entry_stats?.measured_at
            ? `Entry headings in dated daily journals. Last counted ${new Date(agent.journal_entry_stats.measured_at).toLocaleString()}. Refreshes in the background.`
            : 'Entry headings in dated daily journals. Counted in the background without waking the resident.'}>
          <Notebook class="size-4" aria-label="Journal entries" />
          {agent.journal_entry_stats?.count?.toLocaleString() ?? '—'}
          {#if agent.journal_entry_stats?.status === 'unavailable'}
            <span class="opacity-60">
              {agent.journal_entry_stats?.count != null ? '(stale)' : '(unavailable)'}
            </span>
          {/if}
        </span>
        <span
          class="inline-flex items-center gap-1"
          title={`Persistent disk usage across identity, Chaos, repo, work and state volumes. ${agent.journal_entry_stats?.measured_at ? `Measured ${new Date(agent.journal_entry_stats.measured_at).toLocaleString()}.` : 'Awaiting background measurement.'}`}>
          <HardDrive class="size-4" aria-label="Persistent disk used" />
          {diskSize(agent.journal_entry_stats?.storage_bytes)}
          {#if agent.journal_entry_stats?.status === 'unavailable' && agent.journal_entry_stats?.storage_bytes != null}<span
              class="opacity-60">(stale)</span
            >{/if}
        </span>
        <span
          class="inline-flex items-center gap-1 {heartbeatEnabled
            ? 'text-rose-600 dark:text-rose-400'
            : 'text-muted-foreground/40'}"
          title={heartbeatEnabled
            ? `${agent.heartbeat_wakes_per_day} scheduled heartbeats per day`
            : 'Heartbeats disabled or paused'}>
          <Heart
            class="size-4"
            weight={heartbeatEnabled ? 'fill' : 'regular'}
            aria-label={heartbeatEnabled ? 'Daily heartbeats' : 'Heartbeats disabled'} />
          {#if heartbeatEnabled}{agent.heartbeat_wakes_per_day}{/if}
        </span>
      </div>
    {/if}

    {#if agent.provider_subscription?.auth_mode === 'oauth_account'}
      <AgentSubscriptionUsageSummary
        {accountId}
        agentId={agent.id}
        modelId={agent.model_id}
        subscription={agent.provider_subscription} />
    {/if}

    <ResidentActivity days={agent.activity || []} />

    {#if agent.integrations?.length}
      <div class="flex flex-wrap gap-2 mb-3" aria-label="Resident integrations">
        {#each agent.integrations as integration}
          {@const IntegrationIcon = integrationIcons[integration.provider] || Plugs}
          <span
            class={integration.enabled ? 'text-primary' : 'text-muted-foreground/35'}
            title={`${integration.label} · ${integration.status}`}>
            <IntegrationIcon
              class="size-5"
              weight={integration.enabled ? 'fill' : 'regular'}
              aria-label={`${integration.label}: ${integration.status}`} />
          </span>
        {/each}
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
        title="Change this resident's model and preserve a historical, unavailable predecessor record">
        <Copy class="size-4" />
      </Button>
      <Button
        variant="outline"
        size="sm"
        onclick={() => ondisable?.(agent)}
        disabled={!agent.active}
        aria-label={`Disable ${agent.name}`}
        title="Disable resident — preserve their history and files"
        class="text-destructive hover:text-destructive">
        <Trash class="size-4" />
      </Button>
    </div>
  </CardContent>
</Card>
