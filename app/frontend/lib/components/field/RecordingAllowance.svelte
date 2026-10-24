<script>
  import { allowanceLine } from '$lib/field-recordings';

  let { allowance } = $props();

  const percent = $derived(
    allowance.unlimited ? 0 : Math.min(100, Math.round((100 * (allowance.used_ms || 0)) / Math.max(1, allowance.limit_ms || 0)))
  );
</script>

<div class="mb-4 max-w-md" data-testid="recording-allowance">
  <p class="text-sm text-muted-foreground mb-1">{allowanceLine(allowance)}</p>
  {#if !allowance.unlimited}
  <div class="h-1.5 rounded-full bg-muted overflow-hidden">
    <div class="h-full bg-primary/70" style="width: {percent}%"></div>
  </div>
  {/if}
</div>
