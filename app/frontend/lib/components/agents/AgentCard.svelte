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
    ShareNetwork,
    DropboxLogo,
    GoogleLogo,
    Circle,
    Plugs,
    Receipt,
    HardDrives,
    Cloud,
  } from 'phosphor-svelte';
  import AgentAvatar from '$lib/components/agents/AgentAvatar.svelte';
  import { editAccountAgentPath } from '@/routes';
  import AgentSubscriptionUsageSummary from '$lib/components/agents/AgentSubscriptionUsageSummary.svelte';

  import ResidentActivity from './ResidentActivity.svelte';
  import ResidentSessionsSpinner from './ResidentSessionsSpinner.svelte';
  const integrationIcons = {
    telegram: TelegramLogo,
    github: GithubLogo,
    tailscale: ShareNetwork,
    dropbox: DropboxLogo,
    google_workspace: GoogleLogo,
    oura: Circle,
    xero: Receipt,
  };
  function diskSize(bytes) {
    if (bytes == null) return '—';
    if (bytes < 1024 ** 2) return `${(bytes / 1024).toFixed(0)} KiB`;
    if (bytes < 1024 ** 3) return `${(bytes / 1024 ** 2).toFixed(1)} MiB`;
    return `${(bytes / 1024 ** 3).toFixed(1)} GiB`;
  }

  let {
    agent,
    sessions = null,
    accountId,
    onupgrade,
    ondisable,
    showActions = true,
    admin = false,
    canManageProviderSubscription = false,
  } = $props();
  let heartbeatEnabled = $derived(agent.scheduled_wakes_enabled && agent.active && !agent.paused && !agent.deprecated);
  let failedRuns = $derived(agent.failed_runs);
  // Only the site admin's grid sends these.
  let hostingTitle = $derived(
    agent.hosting?.kind === 'cloud'
      ? `Own cloud VM${agent.hosting.location ? ` (${agent.hosting.location})` : ''}${agent.hosting.state === 'ready' ? '' : ` · ${agent.hosting.state}`}`
      : agent.hosting
        ? `On the house server${agent.hosting.state === 'ready' ? '' : ` · ${agent.hosting.state}`}`
        : null
  );
  // The streak start in the reader's own clock; a date only when it isn't today.
  function sinceLabel(iso) {
    if (!iso) return '';
    const since = new Date(iso);
    const time = since.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
    if (since.toDateString() === new Date().toDateString()) return time;
    return `${since.toLocaleDateString([], { day: 'numeric', month: 'short' })} ${time}`;
  }
</script>

<Card
  class="hover:border-primary/50 transition-colors {!agent.active || agent.deprecated ? 'grayscale opacity-60' : ''}">
  <CardHeader class="pb-3">
    <div class="flex items-start justify-between">
      <div class="flex items-center gap-3">
        <AgentAvatar
          {agent}
          class="size-9 rounded-lg flex items-center justify-center"
          fallbackClass={agent.colour ? `bg-${agent.colour}-100 dark:bg-${agent.colour}-900` : 'bg-primary/10'}
          iconClass="size-5 {agent.colour
            ? `text-${agent.colour}-700 dark:text-${agent.colour}-300`
            : 'text-primary'}" />
        <div>
          <div class="flex items-center gap-1.5">
            <CardTitle class="text-lg">{agent.name}</CardTitle>
            {#if agent.hosting}
              <span
                class={agent.hosting.kind === 'cloud' ? 'text-sky-600 dark:text-sky-400' : 'text-muted-foreground'}
                title={hostingTitle}
                data-testid="resident-hosting"
                data-kind={agent.hosting.kind}>
                {#if agent.hosting.kind === 'cloud'}
                  <Cloud class="size-4" weight="duotone" aria-label={hostingTitle} />
                {:else}
                  <HardDrives class="size-4" weight="duotone" aria-label={hostingTitle} />
                {/if}
              </span>
            {/if}
          </div>
          <p class="text-xs font-light text-muted-foreground mt-0.5">
            {agent.model_label || agent.model_id}{#if agent.reasoning_effort}<span class="opacity-50">
                / {agent.reasoning_effort === 'default' ? 'provider default' : agent.reasoning_effort}</span
              >{/if}
          </p>
          {#if agent.account_name || agent.owner_email}
            <p
              class="text-xs text-muted-foreground mt-0.5 truncate"
              title={agent.account_name}
              data-testid="resident-owner">
              {agent.owner_email || 'no owner'}
            </p>
          {/if}
          <div class="flex flex-wrap gap-1 mt-1">
            {#if agent.deprecated}
              <Badge variant="secondary" title="The inline runtime has been retired. History is preserved.">
                Deprecated · Unavailable
              </Badge>
            {/if}
            {#if !agent.active}
              <Badge variant="secondary">Disabled</Badge>
            {/if}
            {#if agent.unavailability_reason === 'billing_hold'}
              <Badge variant="outline" title="The payment for this resident's plan has lapsed. Paying wakes them."
                >Asleep</Badge>
            {/if}
            {#if agent.paused && !agent.deprecated}
              <Badge variant="outline" title="Excluded from cron sweeps. Manual triggers still work.">Paused</Badge>
            {/if}
          </div>
        </div>
      </div>
      <ResidentSessionsSpinner {sessions} />
    </div>
  </CardHeader>
  <CardContent>
    {#if failedRuns && !agent.deprecated}
      <div
        class="mb-3 rounded-md border border-destructive/30 bg-destructive/5 px-3 py-2 text-xs text-destructive"
        data-testid="failed-runs">
        <p class="font-medium">
          Last {failedRuns.capped ? `${failedRuns.count}+` : failedRuns.count} runs failed{failedRuns.since
            ? ` (since ${sinceLabel(failedRuns.since)})`
            : ''}
        </p>
        {#if failedRuns.runtime_unavailable}
          <p class="mt-0.5">{agent.name}'s runtime isn't starting, so a new message won't get a reply.</p>
        {:else if failedRuns.model_unavailable}
          <p class="mt-0.5">
            {agent.name}'s model isn't available on its subscription, so a new message won't get a reply until another
            model is chosen.
          </p>
        {/if}
        {#if showActions && !admin}
          <a
            class="underline mt-0.5 inline-block"
            href={editAccountAgentPath(accountId, agent.id, { tab: 'interactions' })}>See the runs</a>
        {/if}
      </div>
    {/if}
    {#if !agent.deprecated}
      <div class="text-xs text-muted-foreground mb-4 flex flex-wrap gap-x-3 gap-y-0.5">
        <span
          class="inline-flex items-center gap-1"
          title="Nodes / connections in this resident's private graph. Includes all node types and dormant nodes; connections count stored edges. Contents stay private.">
          <Graph class="size-4" aria-label="Mnemodyne nodes / connections" />
          {(agent.mnemodyne_node_count ?? 0).toLocaleString()} / {(agent.mnemodyne_edge_count ?? 0).toLocaleString()}
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
        usageUrl={admin ? `/admin/agents/${agent.id}/provider_subscription_usage` : undefined}
        agentId={agent.id}
        modelId={agent.model_id}
        subscription={agent.provider_subscription}
        canReconnect={canManageProviderSubscription && !admin} />
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
    {#if showActions}
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
    {/if}
  </CardContent>
</Card>
