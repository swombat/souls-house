<script>
  import { router } from '@inertiajs/svelte';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Button } from '$lib/components/shadcn/button';
  import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from '$lib/components/shadcn/table';
  import { agentIconFor } from '$lib/agent-icons';
  import ModelProviderLogo from '$lib/components/ModelProviderLogo.svelte';

  let { account } = $props();
  let metric = $state('sessions');
  let refreshing = $state(false);
  const usage = $derived(account.usage);
  const maxActivity = $derived(Math.max(1, ...usage.activity.map((day) => day[metric])));
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

  function sessionUrl(session) {
    const query = new URLSearchParams({
      session_id: session.session_id,
      from: new Date(new Date(session.last_at).getTime() - 24 * 60 * 60 * 1000).toISOString(),
      to: new Date(new Date(session.last_at).getTime() + 1000).toISOString(),
    });
    return `/admin/agents/${session.agent_id}/runtime?${query}`;
  }

  function providerLabel(provider) {
    return (
      { openai: 'OpenAI', anthropic: 'Anthropic', gemini: 'Google', xai: 'xAI', openrouter: 'OpenRouter' }[provider] ||
      provider
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
      <div
        class="flex h-36 items-end gap-1 border-b"
        role="img"
        aria-label={`${metric} over the last 30 UTC days; daily peak ${periodTotal ? maxActivity : 0}`}>
        {#each usage.activity as day}
          <div
            class="min-w-0 flex-1 rounded-t bg-primary/75 hover:bg-primary"
            style:height={`${day[metric] ? Math.max(3, (day[metric] / maxActivity) * 100) : 0}%`}
            title={`${day.date}: ${day[metric]} ${metric}`}>
          </div>
        {/each}
      </div>
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
      {#each usage.agents as agent (agent.id)}
        {@const ResidentIcon = agentIconFor(agent.icon)}
        {@const deprecated = ['deprecated', 'inline', 'migrating'].includes(agent.runtime)}
        {@const access = agent.model_access}
        <article class={`rounded-lg border p-4 ${deprecated ? 'bg-muted/50 opacity-60 grayscale' : ''}`}>
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="flex items-start gap-3">
              <div
                aria-label={`${agent.name} icon`}
                class={`rounded-lg p-2 ${agent.colour ? `bg-${agent.colour}-100 dark:bg-${agent.colour}-900` : 'bg-primary/10'}`}>
                <ResidentIcon
                  weight="duotone"
                  class={`size-6 ${agent.colour ? `text-${agent.colour}-700 dark:text-${agent.colour}-300` : 'text-primary'}`} />
              </div>
              <div>
                <h3 class="font-semibold">{agent.name}</h3>
                <div class="mt-1 flex flex-wrap gap-2">
                  {#if deprecated}
                    <Badge variant="outline">Deprecated · inline</Badge>
                  {/if}
                  <Badge variant={agent.active && !agent.paused ? 'secondary' : 'outline'}
                    >{!agent.active ? 'Inactive' : agent.paused ? 'Paused' : 'Active'}</Badge>
                  {#if !deprecated && agent.runtime !== 'external'}
                    <Badge variant="outline">{agent.runtime}</Badge>
                  {/if}
                  {#if !deprecated}<Badge variant={agent.health_state === 'unhealthy' ? 'destructive' : 'outline'}
                      >{agent.health_state}</Badge
                    >{/if}
                </div>
              </div>
            </div>
            {#if !deprecated}
              <a class="text-sm text-primary underline underline-offset-4" href={`/admin/agents/${agent.id}/runtime`}
                >Inspect runtime →</a>
            {/if}
          </div>
          <dl class="mt-4 grid gap-4 sm:grid-cols-2 xl:grid-cols-4 text-sm">
            <div>
              <dt class="text-muted-foreground">Model / reasoning</dt>
              <dd class="flex items-center gap-2 break-words font-medium">
                <ModelProviderLogo modelId={agent.model_id} />
                <span>{agent.model}</span>
              </dd>
              <dd class="my-1 flex flex-wrap items-center gap-1.5">
                {#if access?.mode}
                  <Badge variant={access.mode === 'oauth_account' ? 'secondary' : 'outline'}>
                    {access.mode === 'oauth_account' ? 'OAuth' : 'API'} · {providerLabel(access.provider)}
                  </Badge>
                  {#if access.mode === 'oauth_account'}
                    <span class="text-xs text-muted-foreground"
                      >{access.connection_status || 'Connection not confirmed'}</span>
                  {/if}
                {:else}
                  <span class="text-xs text-muted-foreground">Authentication unknown</span>
                {/if}
              </dd>
              <dd>
                {agent.reasoning_effort} reasoning{agent.thinking_enabled
                  ? ` · ${agent.thinking_budget.toLocaleString()} thinking budget`
                  : ''}
              </dd>
            </div>
            <div>
              <dt class="text-muted-foreground">Heartbeat</dt>
              <dd>
                {agent.scheduled_wakes_enabled ? `${agent.heartbeat_wakes_per_day} wakes/day` : 'Scheduled wakes off'}
              </dd>
              <dd class="text-xs text-muted-foreground">
                {!agent.active || agent.paused ? 'Resident is inactive or paused' : 'Configured schedule'}
              </dd>
            </div>
            <div>
              <dt class="text-muted-foreground">Usage · all time</dt>
              <dd>{agent.conversations} conversations · {agent.sessions} sessions</dd>
              <dd>{agent.runs} trigger attempts</dd>
            </div>
            <div>
              <dt class="text-muted-foreground">Persistent disk</dt>
              <dd class="font-medium">
                {deprecated ? 'No hosted volumes' : bytes(agent.storage.bytes)}
              </dd>
              {#if !deprecated}
                <dd class="text-xs text-muted-foreground">
                  {agent.storage.status || 'Awaiting first measurement'}{stale(agent.storage) ? ' · stale' : ''}
                </dd>
                {#if agent.storage.measured_at}<dd class="text-xs text-muted-foreground">
                    Measured {dateTime(agent.storage.measured_at)}
                  </dd>{/if}
                {#if agent.storage.status === 'unavailable'}<dd class="text-xs text-destructive">
                    Latest check failed; any size shown is an older reading.
                  </dd>{/if}
              {/if}
            </div>
          </dl>
          <p class="mt-3 text-xs text-muted-foreground">
            Created {dateTime(agent.created_at)} · Last runtime attempt {dateTime(agent.last_activity_at)}
          </p>
          <details class="mt-3 text-sm">
            <summary class="cursor-pointer font-medium">Settings, integrations & storage breakdown</summary>
            <div class="mt-3 grid gap-4 md:grid-cols-2">
              <dl class="space-y-2">
                <div>
                  <dt class="text-muted-foreground">Persistent sessions</dt>
                  <dd>
                    Chat: {agent.persistent_session ? 'on' : 'off'} · Wake: {agent.persistent_wake_session
                      ? 'on'
                      : 'off'}
                  </dd>
                </div>
                <div>
                  <dt class="text-muted-foreground">Container memory / backups</dt>
                  <dd>{agent.container_memory_mb} MiB RAM · backup interval {agent.backup_interval_hours}h</dd>
                </div>
                <div>
                  <dt class="text-muted-foreground">Voice</dt>
                  <dd>{agent.voice_enabled ? 'On' : 'Off'}</dd>
                </div>
                <div>
                  <dt class="text-muted-foreground">Health last checked</dt>
                  <dd>{dateTime(agent.last_health_check_at)}</dd>
                </div>
                {#each Object.entries(agent.storage.volumes || {}) as [name, size]}<div
                    class="flex justify-between gap-4">
                    <dt class="capitalize">{name}</dt>
                    <dd>{bytes(size)}</dd>
                  </div>{/each}
                {#if agent.storage.missing_volumes?.length}<p class="text-muted-foreground">
                    Unmeasured volumes: {agent.storage.missing_volumes.join(', ')}
                  </p>{/if}
              </dl>
              <div class="space-y-2">
                <p>Telegram: {agent.telegram.configured ? `@${agent.telegram.username}` : 'Not connected'}</p>
                {#each agent.provider_auth.filter((auth) => auth.mode === 'oauth_account') as auth}
                  <p>{auth.provider} subscription: {auth.status || 'not connected'}</p>
                {/each}
                {#each agent.services as service}
                  <div class="rounded border p-2">
                    <div class="font-medium">
                      {service.label} <span class="text-muted-foreground">({service.provider})</span>
                    </div>
                    <p class="text-xs">
                      {service.enabled ? 'Access enabled' : 'Access disabled'} · {service.status} · {service.provisioning_status ||
                        'not provisioned'}
                    </p>
                  </div>
                {:else}<p class="text-muted-foreground">No service connections assigned.</p>{/each}
              </div>
            </div>
          </details>
        </article>
      {:else}<p class="text-sm text-muted-foreground">No residents have been created in this account.</p>{/each}
    </CardContent>
  </Card>

  <Card>
    <CardHeader
      ><CardTitle>Integrations & AI access</CardTitle><CardDescription
        >Connection metadata only—no tokens, keys or external content. An enabled grant may still be pending
        provisioning.</CardDescription
      ></CardHeader>
    <CardContent class="space-y-5">
      <div class="flex flex-wrap gap-2">
        {#each usage.ai_providers.filter((provider) => provider.configured) as provider}<Badge variant="secondary"
            >{provider.provider} API key configured</Badge>
        {:else}<p class="text-sm text-muted-foreground">No account AI API keys configured.</p>{/each}
        <Badge variant="outline">Shared AI fallback {account.use_system_ai_credentials ? 'enabled' : 'disabled'}</Badge>
      </div>
      <p class="text-xs text-muted-foreground">
        Resident subscription authentication and Telegram bots are shown under each resident above.
      </p>
      <div class="overflow-x-auto">
        <Table>
          <TableHeader
            ><TableRow
              ><TableHead>Connection</TableHead><TableHead>Status</TableHead><TableHead>Scope</TableHead><TableHead
                >Resident access enabled</TableHead
              ></TableRow
            ></TableHeader>
          <TableBody>
            {#each usage.integrations as integration}
              <TableRow>
                <TableCell
                  ><div class="font-medium">{integration.label}</div>
                  <div class="text-xs text-muted-foreground">{integration.provider}</div></TableCell>
                <TableCell
                  ><Badge variant={integration.status === 'connected' ? 'secondary' : 'outline'}
                    >{integration.status}</Badge
                  ></TableCell>
                <TableCell
                  >{integration.scope.replaceAll('_', ' ')}{#if integration.enabled_for_new_agents}<div
                      class="text-xs text-muted-foreground">
                      Default for new residents
                    </div>{/if}</TableCell>
                <TableCell>{integration.agents.join(', ') || 'None / account-level'}</TableCell>
              </TableRow>
            {:else}<TableRow
                ><TableCell colspan={4} class="text-muted-foreground"
                  >No account service integrations configured.</TableCell
                ></TableRow
              >{/each}
          </TableBody>
        </Table>
      </div>
    </CardContent>
  </Card>

  <Card>
    <CardHeader
      ><CardTitle>Last 10 runtime sessions</CardTitle><CardDescription
        >Most recently active logical sessions, grouped per resident. A session can contain many trigger attempts. Open
        one to inspect its recent runtime detail.</CardDescription
      ></CardHeader>
    <CardContent class="overflow-x-auto">
      <Table>
        <TableHeader
          ><TableRow
            ><TableHead>Resident / session</TableHead><TableHead>First observed</TableHead><TableHead
              >Last active</TableHead
            ><TableHead>Attempts</TableHead></TableRow
          ></TableHeader>
        <TableBody>
          {#each usage.recent_sessions as session}
            <TableRow
              ><TableCell
                ><a class="text-primary underline underline-offset-4" href={sessionUrl(session)}
                  >{session.agent_name}</a>
                <div class="max-w-56 truncate text-xs text-muted-foreground" title={session.session_id}>
                  {session.session_id}
                </div></TableCell
              ><TableCell>{dateTime(session.first_at)}</TableCell><TableCell>{dateTime(session.last_at)}</TableCell
              ><TableCell>{session.runs}</TableCell></TableRow>
          {:else}<TableRow
              ><TableCell colspan={4} class="text-muted-foreground"
                >No runtime sessions recorded. Inline residents can have conversations without hosted runtime telemetry.</TableCell
              ></TableRow
            >{/each}
        </TableBody>
      </Table>
    </CardContent>
  </Card>

  <Card>
    <CardHeader
      ><CardTitle>Last 10 conversations</CardTitle><CardDescription
        >Most recently updated account conversations. Counts do not expose message contents.</CardDescription
      ></CardHeader>
    <CardContent class="overflow-x-auto">
      <Table>
        <TableHeader
          ><TableRow
            ><TableHead>Conversation</TableHead><TableHead>Residents</TableHead><TableHead>Messages</TableHead
            ><TableHead>Updated</TableHead></TableRow
          ></TableHeader>
        <TableBody>
          {#each usage.recent_conversations as chat}
            <TableRow
              ><TableCell
                ><div class="font-medium">{chat.title}</div>
                <div class="text-xs text-muted-foreground">
                  {chat.id}{chat.discarded ? ' · Deleted' : chat.archived ? ' · Archived' : ''}
                </div></TableCell
              ><TableCell>{chat.agents.join(', ') || 'No residents'}</TableCell><TableCell>{chat.messages}</TableCell
              ><TableCell>{dateTime(chat.updated_at)}</TableCell></TableRow>
          {:else}<TableRow
              ><TableCell colspan={4} class="text-muted-foreground">No conversations yet.</TableCell></TableRow
            >{/each}
        </TableBody>
      </Table>
    </CardContent>
  </Card>
</section>
