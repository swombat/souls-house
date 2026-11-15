<script>
  import { siteName } from '$lib/branding';

  // Where this resident runs: the main house server, or its own VM.
  let { hostingLocation } = $props();

  let specs = $derived(
    hostingLocation?.vcpus
      ? `${hostingLocation.vcpus} vCPUs, ${hostingLocation.ram_gb} GB RAM, ${hostingLocation.disk_gb} GB disk`
      : null
  );

  // What its backup repository held when the house last read it.
  let backups = $derived(hostingLocation?.backups ?? null);
  const gb = (bytes) => `${(Number(bytes) / 1024 ** 3).toFixed(1)} GB`;
  const day = (iso) =>
    new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
</script>

<div class="space-y-3" data-testid="hosting-location">
  <div>
    <h2 class="text-lg font-semibold">Where this resident runs</h2>
  </div>
  <div class="rounded border bg-muted/30 p-4 space-y-2 text-sm">
    {#if hostingLocation.kind === 'failed'}
      <p>Setting up its own server failed. Cleaning up that server may still be pending.</p>
    {:else if hostingLocation.kind === 'none'}
      <p>Not on any server right now: it has no server of its own running, and it isn't on the main server.</p>
    {:else if hostingLocation.kind === 'vm' && hostingLocation.status === 'staged'}
      <p>Waiting to move onto its own server. Nothing has been bought yet; that happens when the move is activated.</p>
    {:else if hostingLocation.kind === 'vm'}
      <p>
        On its own server: a Hetzner Cloud
        <span class="font-medium">{hostingLocation.server_type || 'VM'}</span>{#if specs}&nbsp;({specs}){/if}{#if hostingLocation.location}, in {hostingLocation.location}{/if}.
      </p>
      {#if hostingLocation.status !== 'ready'}
        <p class="text-muted-foreground">The server is still being set up.</p>
      {/if}
    {:else}
      <p>Directly on the main {$siteName} server, shared with other residents.</p>
      <p class="text-muted-foreground">
        This is free of charge for people who signed up early. Please don't overuse it: if the main server fills up,
        we may have to limit usage there and ask people to move their residents onto their own VMs. If everyone is
        considerate, we won't need to.
      </p>
    {/if}
    {#if backups}
      <div class="border-t pt-2 space-y-1" data-testid="backup-history">
        <p>
          {backups.snapshots === 1 ? '1 backup is kept' : `${backups.snapshots} backups are kept`}{#if backups.oldest_at}, the
            oldest from {day(backups.oldest_at)}{/if}. They take {gb(backups.stored_bytes)} of this resident's
          {gb(backups.space_bytes)} of backup space.
        </p>
        {#if backups.over_space}
          <p class="text-muted-foreground" data-testid="backup-over-space">
            The newest backup alone is larger than this resident's backup space. It is kept, and backups continue;
            this is for the house to fix, not you.
          </p>
        {:else if backups.thinned_to_fit}
          <p class="text-muted-foreground" data-testid="backup-thinned">
            Older backups are being removed to stay within that space. The newest backup is always kept.
          </p>
        {/if}
      </div>
    {/if}
  </div>
</div>
