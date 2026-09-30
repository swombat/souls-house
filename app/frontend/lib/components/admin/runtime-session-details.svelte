<script>
  import { Button } from '$lib/components/shadcn/button';
  import {
    aggregateNumber,
    aggregateBytes,
    duration,
    timestamp,
    list,
    mapSummary,
    telemetryClass,
  } from '$lib/runtime-report-formatting';
  import RuntimeOutput from '$lib/components/agents/RuntimeOutput.svelte';
  import RuntimeInvocationTable from './runtime-invocation-table.svelte';
  let { session, selected = false, selectSession } = $props();
</script>

<details class="rounded border bg-muted/10" open={selected}>
  <summary class="cursor-pointer list-none p-4">
    <div class="grid gap-3 xl:grid-cols-[minmax(18rem,2fr)_repeat(6,minmax(7rem,1fr))] xl:items-center">
      <div class="min-w-0">
        <div class="truncate font-mono text-sm">{session.session_id}</div>
        <div class="mt-1 text-xs text-muted-foreground">
          {list(session.trigger_kinds)} · {timestamp(session.first_observed_at)} → {timestamp(session.last_observed_at)}
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
        {aggregateNumber(session.tokens.cache_read_input_tokens, session.token_unknown_rows.cache_read_input_tokens)}
      </div>
      <div>
        <div class="text-xs text-muted-foreground">Telemetry</div>
        <span class={`inline-flex rounded border px-2 py-0.5 text-xs ${telemetryClass(session.telemetry_state)}`}>
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

    <section class="space-y-3" aria-label="Session output">
      <div>
        <h3 class="font-semibold">Session output</h3>
        <p class="text-xs text-muted-foreground">
          Captured stdout, in trigger order—not a complete transcript. Output may contain private resident content. Only
          the final 4,000 characters of each stream are retained per trigger.
        </p>
      </div>
      {#each session.interactions as interaction (interaction.id)}
        <article class="min-w-0 rounded border bg-background p-3">
          <h4 class="mb-2 text-sm font-medium">
            {timestamp(interaction.started_at)} · {interaction.trigger_kind || 'unknown trigger'}
          </h4>
          <RuntimeOutput {interaction} />
        </article>
      {/each}
    </section>

    <RuntimeInvocationTable {session} />
  </div>
</details>
