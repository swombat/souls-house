<script>
  import { siteName } from '$lib/branding';

  // Where this resident runs: the main house server, or its own VM.
  let { hostingLocation } = $props();

  let specs = $derived(
    hostingLocation?.vcpus
      ? `${hostingLocation.vcpus} vCPUs, ${hostingLocation.ram_gb} GB RAM, ${hostingLocation.disk_gb} GB disk`
      : null
  );
</script>

<div class="space-y-3" data-testid="hosting-location">
  <div>
    <h2 class="text-lg font-semibold">Where this resident runs</h2>
  </div>
  <div class="rounded border bg-muted/30 p-4 space-y-2 text-sm">
    {#if hostingLocation.kind === 'vm'}
      <p>
        On its own server: a Hetzner Cloud
        <span class="font-medium">{hostingLocation.server_type || 'VM'}</span>{#if specs}&nbsp;({specs}){/if}{#if hostingLocation.location}, in {hostingLocation.location}{/if}.
      </p>
      {#if !hostingLocation.ready}
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
  </div>
</div>
