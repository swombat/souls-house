<script>
  import ActivityBars from '$lib/components/charts/activity-bars.svelte';
  import AccountRecentConversations from '$lib/components/admin/account-recent-conversations.svelte';
  import AccountRecentSessions from '$lib/components/admin/account-recent-sessions.svelte';
  import AccountIntegrations from '$lib/components/admin/account-integrations.svelte';
  import { router } from '@inertiajs/svelte';

  import { Button } from '$lib/components/shadcn/button';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  import AgentGrid from '$lib/components/agents/AgentGrid.svelte';

  let { account } = $props();
  let metric = $state('sessions');
  let refreshing = $state(false);
  const usage = $derived(account.usage);
  const maxActivity = $derived(Math.max(1, ...usage.activity.map((day) => day[metric])));
  const activityGroups = $derived(
    usage.activity.map((day) => ({
      key: day.date,
      bars: [
        {
          title: `${day.date}: ${day[metric]} ${metric}`,
          segments: [{ value: day[metric], colour: 'rounded-t bg-primary/75 hover:bg-primary' }],
        },
      ],
    }))
  );
  const periodTotal = $derived(usage.activity.reduce((total, day) => total + day[metric], 0));
  const measuredAgents = $derived(
    usage.agents.filter(
      (agent) => ['external', 'offline', 'provisioning'].includes(agent.runtime) && agent.storage.bytes != null
    )
  );
  const storageBytes = $derived(measuredAgents.reduce((total, agent) => total + agent.storage.bytes, 0));
  const hostedAgents = $derived(
    usage.agents.filter((agent) => ['external', 'offline', 'provisioning'].includes(agent.runtime))
  );
  const uncertainReadings = $derived(
    measuredAgents.filter((agent) => agent.storage.status !== 'measured' || stale(agent.storage)).length
  );

  function dateTime(value) {
    return value ? new Date(value).toLocaleString() : 'Never';
  }

  function bytes(value) {
    if (value == null) return 'Not measured';
    const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
    const index = Math.min(4, Math.floor(Math.log(Math.max(1, value)) / Math.log(1024)));
    return `${(value / 1024 ** index).toLocaleString(undefined, { maximumFractionDigits: 1 })} ${units[index]}`;
  }

  function stale(storage) {
    return storage.measured_at && new Date(usage.generated_at) - new Date(storage.measured_at) > 2 * 60 * 60 * 1000;
  }

  function refreshStorage() {
    refreshing = true;
    router.post(
      `/admin/accounts/${account.id}/refresh_storage`,
      {},
      {
        preserveScroll: true,
        onFinish: () => {
          refreshing = false;
        },
      }
    );
  }
</script>

<section class="mb-8 space-y-6" aria-label="Account usage overview">
  <div class="flex flex-wrap items-center justify-between gap-3">
    <div>
      <h2 class="text-xl font-semibold">Usage overview</h2>
      <p class="text-xs text-muted-foreground">As of {dateTime(usage.generated_at)}</p>
    </div>
    <Button variant="outline" size="sm" onclick={() => router.reload({ only: ['selected_account'] })}>
      Refresh overview
    </Button>
  </div>

  <div class="grid grid-cols-2 gap-3 xl:grid-cols-4">
    {#each [['Residents', usage.summary.agents, `${usage.summary.active_agents} enabled and unpaused`], ['Conversations', usage.summary.conversations, 'All account chats, including archived/deleted'], ['Runtime sessions', usage.summary.sessions, `${usage.summary.runs.toLocaleString()} trigger attempts (including busy retries)`], ['Measured storage', measuredAgents.length ? bytes(storageBytes) : 'Not measured', `${measuredAgents.length}/${hostedAgents.length} hosted residents have readings${uncertainReadings ? ` · ${uncertainReadings} stale, partial or unavailable` : ''}`]] as [label, value, detail]}
      <div class="rounded-lg border bg-card p-4">
        <div class="text-sm text-muted-foreground">{label}</div>
        <div class="my-1 text-2xl font-semibold tabular-nums">{value}</div>
        <div class="text-xs text-muted-foreground">{detail}</div>
      </div>
    {/each}
  </div>

  <Card>
    <CardHeader>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <CardTitle>Activity · last 30 days</CardTitle>
        <select
          aria-label="Activity metric"
          bind:value={metric}
          class="rounded-md border bg-background px-3 py-2 text-sm">
          <option value="sessions">Active runtime sessions</option>
          <option value="runs">Trigger attempts</option>
          <option value="conversations">Conversations created</option>
        </select>
      </div>
      <CardDescription>
        UTC days. {metric === 'sessions'
          ? 'Distinct sessions active each day; a continuing session can appear on several days. Busy retries excluded.'
          : metric === 'runs'
            ? 'Includes messages, heartbeats, scheduled work and busy retries.'
            : 'New account chats, including archived and soft-deleted conversations.'}
      </CardDescription>
    </CardHeader>
    <CardContent>
      <div class="mb-2 text-sm text-muted-foreground">
        Daily peak: {maxActivity === 1 && periodTotal === 0 ? 0 : maxActivity}
      </div>
      <ActivityBars
        groups={activityGroups}
        class="h-36 border-b"
        minimumHeight={3}
        label={`${metric} over the last 30 UTC days; daily peak ${periodTotal ? maxActivity : 0}`} />
      <div class="mt-2 flex justify-between text-xs text-muted-foreground">
        <span>{usage.activity[0]?.date}</span><span>{usage.activity.at(-1)?.date}</span>
      </div>
      {#if !periodTotal}<p class="mt-3 text-sm text-muted-foreground">No activity in this period.</p>{/if}
      <details class="mt-4 text-sm">
        <summary class="cursor-pointer text-muted-foreground">View daily counts</summary>
        <div class="mt-2 max-h-60 overflow-auto">
          <Table>
            <TableHeader
              ><TableRow
                ><TableHead>UTC date</TableHead><TableHead>Sessions</TableHead><TableHead>Attempts</TableHead><TableHead
                  >New conversations</TableHead
                ></TableRow
              ></TableHeader>
            <TableBody
              >{#each usage.activity.toReversed() as day}<TableRow
                  ><TableCell>{day.date}</TableCell><TableCell>{day.sessions}</TableCell><TableCell
                    >{day.runs}</TableCell
                  ><TableCell>{day.conversations}</TableCell></TableRow
                >{/each}</TableBody>
          </Table>
        </div>
      </details>
    </CardContent>
  </Card>

  <Card>
    <CardHeader>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <CardTitle>Residents ({usage.agents.length})</CardTitle>
        <Button variant="outline" size="sm" disabled={refreshing || !hostedAgents.length} onclick={refreshStorage}>
          {refreshing ? 'Queuing…' : 'Measure storage'}
        </Button>
      </div>
      <CardDescription>
        Disk readings cover persistent identity, Chaos, repository, work and state volumes—not shared images, container
        layers, database records or remote backups. Collected hourly without waking residents. Refresh after requesting
        a measurement.
      </CardDescription>
    </CardHeader>
    <CardContent class="space-y-4">
      {#key account.id}
        <AgentGrid agents={usage.resident_cards || []} accountId={account.id} showActions={false} admin />
      {/key}
      {#if !usage.agents.length}<p class="text-sm text-muted-foreground">
          No residents have been created in this account.
        </p>{/if}
    </CardContent>
  </Card>

  <AccountIntegrations {account} />
  <AccountRecentSessions {usage} />
  <AccountRecentConversations {usage} />
</section>
