<script>
  import { router } from '@inertiajs/svelte';
  import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '$lib/components/shadcn/card';
  import { Button } from '$lib/components/shadcn/button';
  import { siteName } from '$lib/branding';

  let { agent, report, filters, selected_session_id = null } = $props();

  let fromValue = $state(toUtcInput(filters.from));
  let toValue = $state(toUtcInput(filters.to));
  let triggerKind = $state(filters.trigger_kind || '');
  let provider = $state(filters.provider || '');
  let model = $state(filters.model || '');
  let sessionOutcome = $state(filters.session_outcome || '');
  let sessionRollReason = $state(filters.session_roll_reason || '');

  const tokenLabels = {
    uncached_input_tokens: 'Ordinary input',
    cache_creation_input_tokens: 'Cache writes',
    cache_read_input_tokens: 'Cache reads',
    output_tokens: 'Output',
    reasoning_output_tokens: 'Reasoning output',
  };

  function toUtcInput(value) {
    return value ? new Date(value).toISOString().slice(0, 16) : '';
  }

  function utcIso(value) {
    return value ? `${value}:00Z` : undefined;
  }

  function reportParams(extra = {}) {
    return compact({
      from: utcIso(fromValue),
      to: utcIso(toValue),
      trigger_kind: triggerKind,
      provider,
      model,
      session_outcome: sessionOutcome,
      session_roll_reason: sessionRollReason,
      ...extra,
    });
  }

  function compact(values) {
    return Object.fromEntries(Object.entries(values).filter(([, value]) => value !== '' && value != null));
  }

  function applyFilters(event) {
    event.preventDefault();
    router.get(window.location.pathname, reportParams(), { preserveState: false, preserveScroll: true });
  }

  function clearFilters() {
    triggerKind = '';
    provider = '';
    model = '';
    sessionOutcome = '';
    sessionRollReason = '';
    router.get(window.location.pathname, { from: utcIso(fromValue), to: utcIso(toValue) });
  }

  function selectSession(sessionId) {
    router.get(window.location.pathname, reportParams({ session_id: sessionId }), {
      preserveState: true,
      preserveScroll: true,
    });
  }

  function number(value) {
    return value === null || value === undefined ? 'unknown' : new Intl.NumberFormat('en-US').format(value);
  }

  function aggregateNumber(value, unknownRows) {
    if (value === null || value === undefined) return 'unknown';
    return unknownRows > 0 ? `${number(value)} known (+ ${unknownRows} unknown)` : number(value);
  }

  function bytes(value) {
    if (value === null || value === undefined) return 'unknown';
    if (value < 1024) return `${value} B`;
    if (value < 1024 * 1024) return `${(value / 1024).toFixed(1)} KiB`;
    return `${(value / 1024 / 1024).toFixed(1)} MiB`;
  }

  function aggregateBytes(value, unknownRows) {
    if (value === null || value === undefined) return 'unknown';
    return unknownRows > 0 ? `${bytes(value)} known (+ ${unknownRows} unknown)` : bytes(value);
  }

  function duration(value) {
    if (value === null || value === undefined) return 'unknown';
    if (value < 1000) return `${value} ms`;
    if (value < 60_000) return `${(value / 1000).toFixed(1)} s`;
    if (value < 3_600_000) return `${(value / 60_000).toFixed(1)} min`;
    return `${(value / 3_600_000).toFixed(1)} h`;
  }

  function timestamp(value) {
    if (!value) return 'unknown';
    return (
      new Intl.DateTimeFormat('en-GB', {
        timeZone: 'UTC',
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit',
        hour12: false,
      }).format(new Date(value)) + ' UTC'
    );
  }

  function list(values) {
    return values?.length ? values.join(', ') : 'unknown';
  }

  function booleanState(value) {
    if (value === true) return 'yes';
    if (value === false) return 'no';
    return 'unknown';
  }

  function mapSummary(values) {
    const entries = Object.entries(values || {});
    return entries.length ? entries.map(([key, value]) => `${key}: ${value}`).join(' · ') : 'none';
  }

  function telemetryClass(state) {
    if (state === 'complete')
      return 'border-green-300 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950 dark:text-green-300';
    if (state === 'unsupported')
      return 'border-red-300 bg-red-50 text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-300';
    return 'border-amber-300 bg-amber-50 text-amber-800 dark:border-amber-900 dark:bg-amber-950 dark:text-amber-300';
  }

  function lifecycleClass(outcome) {
    if (outcome === 'resumed') return 'bg-green-100 text-green-800 dark:bg-green-950 dark:text-green-300';
    if (outcome === 'rolled' || outcome === 'fresh_fallback' || outcome === 'resume_timeout')
      return 'bg-amber-100 text-amber-800 dark:bg-amber-950 dark:text-amber-300';
    if (outcome === 'failed') return 'bg-red-100 text-red-800 dark:bg-red-950 dark:text-red-300';
    return 'bg-slate-100 text-slate-800 dark:bg-slate-900 dark:text-slate-300';
  }
</script>

<svelte:head>
  <title>{agent.name} runtime usage</title>
</svelte:head>

<div class="container mx-auto max-w-[1800px] space-y-6 px-4 py-8">
  <div>
    <p class="text-sm text-muted-foreground">{agent.account_name} · {agent.runtime}</p>
    <h1 class="text-2xl font-bold">{agent.name} runtime usage</h1>
    <p class="mt-1 text-sm text-muted-foreground">
      Invocation-local usage grouped by {$siteName} logical session. The window and every timestamp below are UTC.
    </p>
  </div>

  <Card>
    <CardHeader>
      <CardTitle>Report window and filters</CardTitle>
      <CardDescription>
        {report.window.from} through {report.window.to}. The reporting service only sums stored invocation fields; it
        never reconstructs historical runtime usage.
      </CardDescription>
    </CardHeader>
    <CardContent>
      <form class="grid gap-3 md:grid-cols-2 xl:grid-cols-4" onsubmit={applyFilters}>
        <label class="grid gap-1 text-xs text-muted-foreground">
          From (UTC)
          <input
            class="rounded border bg-background px-2 py-1.5 text-sm text-foreground"
            type="datetime-local"
            bind:value={fromValue} />
        </label>
        <label class="grid gap-1 text-xs text-muted-foreground">
          To (UTC)
          <input
            class="rounded border bg-background px-2 py-1.5 text-sm text-foreground"
            type="datetime-local"
            bind:value={toValue} />
        </label>
        <label class="grid gap-1 text-xs text-muted-foreground">
          Trigger kind
          <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={triggerKind}>
            <option value="">All</option>
            {#each report.filter_options.trigger_kind as value}<option {value}>{value}</option>{/each}
          </select>
        </label>
        <label class="grid gap-1 text-xs text-muted-foreground">
          Provider
          <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={provider}>
            <option value="">All</option>
            {#each report.filter_options.provider as value}<option {value}>{value}</option>{/each}
          </select>
        </label>
        <label class="grid gap-1 text-xs text-muted-foreground">
          Model
          <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={model}>
            <option value="">All</option>
            {#each report.filter_options.model as value}<option {value}>{value}</option>{/each}
          </select>
        </label>
        <label class="grid gap-1 text-xs text-muted-foreground">
          Session outcome
          <select class="rounded border bg-background px-2 py-1.5 text-sm text-foreground" bind:value={sessionOutcome}>
            <option value="">All</option>
            {#each report.filter_options.session_outcome as value}<option {value}>{value}</option>{/each}
          </select>
        </label>
        <label class="grid gap-1 text-xs text-muted-foreground">
          Roll reason
          <select
            class="rounded border bg-background px-2 py-1.5 text-sm text-foreground"
            bind:value={sessionRollReason}>
            <option value="">All</option>
            {#each report.filter_options.session_roll_reason as value}<option {value}>{value}</option>{/each}
          </select>
        </label>
        <div class="flex items-end gap-2">
          <Button type="submit" size="sm">Apply</Button>
          <Button type="button" size="sm" variant="outline" onclick={clearFilters}>Clear dimensions</Button>
        </div>
      </form>
    </CardContent>
  </Card>

  <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
    <Card>
      <CardHeader class="pb-2"><CardDescription>Interactions</CardDescription></CardHeader>
      <CardContent>
        <div class="text-2xl font-semibold">{number(report.summary.interactions)}</div>
        {#if report.summary.busy_retries > 0}
          <div class="mt-1 text-xs font-normal text-muted-foreground">
            {number(report.summary.busy_retries)} busy retries excluded
          </div>
        {/if}
      </CardContent>
    </Card>
    <Card>
      <CardHeader class="pb-2"><CardDescription>Logical sessions</CardDescription></CardHeader>
      <CardContent class="text-2xl font-semibold">{number(report.summary.logical_sessions)}</CardContent>
    </Card>
    <Card>
      <CardHeader class="pb-2"><CardDescription>Chaos processes</CardDescription></CardHeader>
      <CardContent class="text-2xl font-semibold">{number(report.summary.chaos_processes)}</CardContent>
    </Card>
    <Card>
      <CardHeader class="pb-2"><CardDescription>Provider requests</CardDescription></CardHeader>
      <CardContent class="text-xl font-semibold">
        {aggregateNumber(report.summary.provider_requests, report.summary.provider_request_unknown_rows)}
      </CardContent>
    </Card>
    <Card>
      <CardHeader class="pb-2"><CardDescription>Detailed telemetry</CardDescription></CardHeader>
      <CardContent class="text-sm">
        <div>{report.summary.complete_usage_rows} complete</div>
        <div class="text-amber-700 dark:text-amber-400">
          {report.summary.incomplete_usage_rows} incomplete · {report.summary.unavailable_usage_rows} unavailable
        </div>
        {#if report.summary.unsupported_usage_rows > 0}
          <div class="text-red-700 dark:text-red-400">{report.summary.unsupported_usage_rows} unsupported</div>
        {/if}
      </CardContent>
    </Card>
  </div>

  <div class="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
    {#each Object.entries(tokenLabels) as [key, label]}
      <Card>
        <CardHeader class="pb-2"><CardDescription>{label}</CardDescription></CardHeader>
        <CardContent class="text-lg font-semibold">
          {aggregateNumber(report.summary.tokens[key], report.summary.token_unknown_rows[key])}
        </CardContent>
      </Card>
    {/each}
  </div>

  <Card>
    <CardHeader>
      <CardTitle>Session breakdown</CardTitle>
      <CardDescription>
        {report.summary.fresh} fresh · {report.summary.resumed} resumed · {report.summary.rolled} rolled ·
        {report.summary.fallbacks} fallbacks. Selected prompts:
        {aggregateBytes(report.summary.selected_prompt_bytes, report.summary.selected_prompt_unknown_rows)}.
      </CardDescription>
    </CardHeader>
    <CardContent class="space-y-3">
      {#if report.sessions.length === 0}
        <p class="text-sm text-muted-foreground">
          No runtime interactions were recorded in this UTC window and filter set.
        </p>
      {/if}

      {#each report.sessions as session}
        <details class="rounded border bg-muted/10" open={selected_session_id === session.session_id}>
          <summary class="cursor-pointer list-none p-4">
            <div class="grid gap-3 xl:grid-cols-[minmax(18rem,2fr)_repeat(6,minmax(7rem,1fr))] xl:items-center">
              <div class="min-w-0">
                <div class="truncate font-mono text-sm">{session.session_id}</div>
                <div class="mt-1 text-xs text-muted-foreground">
                  {list(session.trigger_kinds)} · {timestamp(session.first_observed_at)} → {timestamp(
                    session.last_observed_at
                  )}
                </div>
              </div>
              <div>
                <div class="text-xs text-muted-foreground">Duration</div>
                {duration(session.active_duration_ms)}
              </div>
              <div>
                <div class="text-xs text-muted-foreground">Interactions</div>
                {session.interaction_count}
              </div>
              <div>
                <div class="text-xs text-muted-foreground">Processes</div>
                {session.chaos_process_count}
              </div>
              <div>
                <div class="text-xs text-muted-foreground">Provider calls</div>
                {aggregateNumber(session.provider_request_count, session.provider_request_unknown_rows)}
              </div>
              <div>
                <div class="text-xs text-muted-foreground">Cache reads</div>
                {aggregateNumber(
                  session.tokens.cache_read_input_tokens,
                  session.token_unknown_rows.cache_read_input_tokens
                )}
              </div>
              <div>
                <div class="text-xs text-muted-foreground">Telemetry</div>
                <span
                  class={`inline-flex rounded border px-2 py-0.5 text-xs ${telemetryClass(session.telemetry_state)}`}>
                  {session.telemetry_state}
                </span>
              </div>
            </div>
          </summary>

          <div class="space-y-4 border-t p-4">
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div class="grid flex-1 gap-2 text-sm md:grid-cols-2 xl:grid-cols-4">
                <div>
                  <span class="text-muted-foreground">Latest outcome:</span>
                  {session.latest_outcome || 'unknown'}
                </div>
                <div><span class="text-muted-foreground">Providers:</span> {list(session.providers)}</div>
                <div><span class="text-muted-foreground">Models:</span> {list(session.models)}</div>
                <div><span class="text-muted-foreground">Cache TTLs:</span> {list(session.cache_ttls)}</div>
                <div><span class="text-muted-foreground">Chaos versions:</span> {list(session.chaos_versions)}</div>
                <div><span class="text-muted-foreground">Outcomes:</span> {mapSummary(session.outcomes)}</div>
                <div><span class="text-muted-foreground">Roll reasons:</span> {mapSummary(session.roll_reasons)}</div>
                <div>
                  <span class="text-muted-foreground">Selected prompts:</span>
                  {aggregateBytes(session.selected_prompt_bytes, session.selected_prompt_unknown_rows)}
                </div>
              </div>
              <Button type="button" size="sm" variant="outline" onclick={() => selectSession(session.session_id)}>
                Permalink timeline
              </Button>
            </div>

            {#if session.telemetry_state !== 'complete'}
              <div class={`rounded border p-3 text-sm ${telemetryClass(session.telemetry_state)}`}>
                Detailed invocation telemetry is not complete for every row in this session:
                {mapSummary(session.telemetry_states)}. Values marked unknown were not reported and are not zero.
              </div>
            {/if}

            <div class="overflow-x-auto">
              <table class="w-full min-w-[1680px] text-left text-xs">
                <thead class="border-b text-muted-foreground">
                  <tr>
                    <th class="px-2 py-2">UTC range / duration</th>
                    <th class="px-2 py-2">Lifecycle decision</th>
                    <th class="px-2 py-2">Chaos process transition</th>
                    <th class="px-2 py-2">Prompt bytes</th>
                    <th class="px-2 py-2">Runtime</th>
                    <th class="px-2 py-2">Calls</th>
                    <th class="px-2 py-2">Ordinary</th>
                    <th class="px-2 py-2">Write</th>
                    <th class="px-2 py-2">Read</th>
                    <th class="px-2 py-2">Output</th>
                    <th class="px-2 py-2">Reasoning</th>
                    <th class="px-2 py-2">Telemetry</th>
                  </tr>
                </thead>
                <tbody>
                  {#each session.interactions as interaction}
                    <tr class="border-b align-top last:border-0">
                      <td class="px-2 py-3">
                        <div>{timestamp(interaction.started_at)}</div>
                        <div>{timestamp(interaction.finished_at)}</div>
                        <div class="text-muted-foreground">{duration(interaction.duration_ms)}</div>
                      </td>
                      <td class="px-2 py-3">
                        <span class={`inline-flex rounded px-2 py-0.5 ${lifecycleClass(interaction.session_outcome)}`}>
                          {interaction.session_outcome || 'unknown'}
                        </span>
                        <div class="mt-1">{interaction.session_roll_reason || 'no roll reason'}</div>
                        <div class="text-muted-foreground">
                          persistent {booleanState(interaction.persistent_session_requested)} · mapping
                          {booleanState(interaction.session_mapping_found)} · resume attempted
                          {booleanState(interaction.resume_attempted)}
                        </div>
                        <div class="text-muted-foreground">
                          sequence {number(interaction.session_trigger_sequence)} · age {duration(
                            interaction.session_age_seconds == null ? null : interaction.session_age_seconds * 1000
                          )}
                        </div>
                        {#if interaction.changed_identity_files?.length}
                          <div class="text-muted-foreground">
                            changed: {interaction.changed_identity_files.join(', ')}
                          </div>
                        {/if}
                      </td>
                      <td class="px-2 py-3 font-mono">
                        <div>{interaction.chaos_session_id || 'unknown'}</div>
                        {#if interaction.prior_chaos_session_id}
                          <div class="text-muted-foreground">from {interaction.prior_chaos_session_id}</div>
                        {:else}
                          <div class="text-muted-foreground">prior unknown</div>
                        {/if}
                      </td>
                      <td class="px-2 py-3">
                        <div>
                          {interaction.prompt_mode || 'unknown'} selected {bytes(interaction.selected_prompt_bytes)}
                        </div>
                        <div class="text-muted-foreground">full {bytes(interaction.full_prompt_bytes)}</div>
                        <div class="text-muted-foreground">delta {bytes(interaction.delta_prompt_bytes)}</div>
                        {#if Object.keys(interaction.prompt_component_bytes || {}).length}
                          <div class="text-muted-foreground">
                            {Object.entries(interaction.prompt_component_bytes)
                              .map(([key, value]) => `${key} ${bytes(value)}`)
                              .join(' · ')}
                          </div>
                        {/if}
                      </td>
                      <td class="px-2 py-3">
                        <div>{interaction.provider || 'unknown'} / {interaction.model || 'unknown'}</div>
                        <div class="text-muted-foreground">TTL {interaction.cache_ttl || 'unknown'}</div>
                        <div class="text-muted-foreground">{interaction.chaos_version || 'Chaos version unknown'}</div>
                        <div class="text-muted-foreground">
                          Chaos telemetry {interaction.chaos_telemetry_status || 'unknown'}
                          {#if interaction.unsupported_chaos_telemetry_schema_version}
                            (schema {interaction.unsupported_chaos_telemetry_schema_version})
                          {/if}
                        </div>
                        <div class="text-muted-foreground">
                          transport {number(interaction.transport_status)} · runtime {interaction.runtime_status ||
                            'unknown'} /
                          {number(interaction.runtime_returncode)}
                        </div>
                      </td>
                      <td class="px-2 py-3">{number(interaction.provider_request_count)}</td>
                      <td class="px-2 py-3">{number(interaction.tokens.uncached_input_tokens)}</td>
                      <td class="px-2 py-3">{number(interaction.tokens.cache_creation_input_tokens)}</td>
                      <td class="px-2 py-3">{number(interaction.tokens.cache_read_input_tokens)}</td>
                      <td class="px-2 py-3">{number(interaction.tokens.output_tokens)}</td>
                      <td class="px-2 py-3">{number(interaction.tokens.reasoning_output_tokens)}</td>
                      <td class="px-2 py-3">
                        <span
                          class={`inline-flex rounded border px-2 py-0.5 ${telemetryClass(interaction.telemetry_state)}`}>
                          {interaction.telemetry_state}
                        </span>
                        <div class="mt-1 max-w-56 text-muted-foreground">{interaction.telemetry_state_reason}</div>
                        <div class="text-muted-foreground">
                          schema {number(interaction.telemetry_schema_version)} · scope {interaction.usage_scope ||
                            'unknown'}
                        </div>
                      </td>
                    </tr>
                  {/each}
                </tbody>
              </table>
            </div>
          </div>
        </details>
      {/each}
    </CardContent>
  </Card>
</div>
