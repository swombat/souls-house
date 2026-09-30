<script>
  import {
    number,
    bytes,
    duration,
    timestamp,
    booleanState,
    telemetryClass,
    lifecycleClass,
  } from '$lib/runtime-report-formatting';
  let { session } = $props();
</script>

<details>
  <summary class="cursor-pointer py-2 text-sm font-medium">Technical invocation breakdown</summary>
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
              <div class="text-muted-foreground">
                {interaction.chaos_version || 'Chaos version unknown'}
              </div>
              <div class="text-muted-foreground">
                Chaos telemetry {interaction.chaos_telemetry_status || 'unknown'}
                {#if interaction.unsupported_chaos_telemetry_schema_version}
                  (schema {interaction.unsupported_chaos_telemetry_schema_version})
                {/if}
              </div>
              <div class="text-muted-foreground">
                transport {number(interaction.transport_status)} · runtime {interaction.runtime_status || 'unknown'} /
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
              <span class={`inline-flex rounded border px-2 py-0.5 ${telemetryClass(interaction.telemetry_state)}`}>
                {interaction.telemetry_state}
              </span>
              <div class="mt-1 max-w-56 text-muted-foreground">{interaction.telemetry_state_reason}</div>
              <div class="text-muted-foreground">
                schema {number(interaction.telemetry_schema_version)} · scope {interaction.usage_scope || 'unknown'}
              </div>
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
  </div>
</details>
