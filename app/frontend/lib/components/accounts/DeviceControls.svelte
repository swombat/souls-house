<script>
  // Pause, resume and remove for one device, with its connection line.
  import { Pause, Play, Trash } from 'phosphor-svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';

  let { device, state, busy = false, offline, online, onsend, onremove } = $props();

  const enrolled = (iso) =>
    iso ? new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' }) : null;
</script>

<div class="flex flex-wrap items-center justify-between gap-2">
  <p class="text-sm text-muted-foreground">
    {#if state === 'paused'}
      Nothing runs here until you resume it.
    {:else if state === 'offline'}
      {offline}
    {:else}
      {online}
    {/if}
    {#if device.enrolled_at}
      <span class="block text-xs">Enrolled {enrolled(device.enrolled_at)}</span>
    {/if}
  </p>
  <div class="flex gap-2">
    {#if device.paused}
      <Button variant="outline" size="sm" disabled={busy} onclick={() => onsend({ control: 'resume' })}>
        <Play class="mr-1" size={16} /> Resume
      </Button>
    {:else}
      <Button variant="outline" size="sm" disabled={busy} onclick={() => onsend({ control: 'pause' })}>
        <Pause class="mr-1" size={16} /> Pause
      </Button>
    {/if}
    <Button
      variant="ghost"
      size="sm"
      class="text-destructive hover:text-destructive"
      disabled={busy}
      onclick={onremove}
      aria-label="Remove {device.name}">
      <Trash size={16} />
    </Button>
  </div>
</div>
