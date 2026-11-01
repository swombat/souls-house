<script>
  import { MESSAGE_TELEMETRY_FIELDS, formatTelemetryTokens } from '$lib/message-telemetry';
  import { ADMIN_ONLY_TEXT } from '$lib/admin-only.js';

  let { telemetry } = $props();
</script>

<div
  class={`ml-auto flex flex-wrap items-center justify-end gap-x-2 text-[11px] ${
    // Site admins only. Incomplete telemetry keeps its amber warning.
    telemetry.instrumentation_complete ? ADMIN_ONLY_TEXT : 'text-amber-700 dark:text-amber-400'
  }`}
  title={telemetry.instrumentation_complete
    ? 'RubyLLM token usage for this message'
    : 'RubyLLM telemetry is incomplete for this message; unavailable values are shown as —'}>
  <span class="font-sans font-medium">{telemetry.model || 'Unknown model'}</span>
  {#each MESSAGE_TELEMETRY_FIELDS as [key, label]}
    <span class="whitespace-nowrap">{label} {formatTelemetryTokens(telemetry[key])}</span>
  {/each}
</div>
