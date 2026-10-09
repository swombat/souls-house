<script>
  import { router } from '@inertiajs/svelte';
  import { Switch } from '$lib/components/shadcn/switch';
  import TailnetAccess from '$lib/components/agents/tailnet-access.svelte';
  let { connection } = $props();
  // Tailscale: every granted resident is its own node and signs in once, here.
  let tailnetResidents = $derived(
    connection.provider === 'tailscale' ? connection.residents.filter((resident) => resident.tailnet_url) : []
  );
  let residentAccessUpdating = $state({});
  function residentTransition(resident) {
    if (resident.provisioning_status === 'pending') return 'Adding…';
    if (resident.provisioning_status === 'removal_pending') return 'Removing…';
    if (resident.provisioning_status && resident.provisioning_status !== 'provisioned') {
      return resident.provisioning_status.replaceAll('_', ' ');
    }
    return null;
  }

  function residentAccessKey(connection, resident) {
    return `${connection.id}:${resident.id}`;
  }

  function toggleResidentAccess(connection, resident, enabled) {
    const key = residentAccessKey(connection, resident);
    residentAccessUpdating = { ...residentAccessUpdating, [key]: true };
    router.patch(
      resident.access_update_url,
      { enabled },
      {
        preserveScroll: true,
        onFinish() {
          const next = { ...residentAccessUpdating };
          delete next[key];
          residentAccessUpdating = next;
        },
      }
    );
  }
</script>

<div class="space-y-3 border-t pt-4">
  <h4 class="text-sm font-semibold">Resident access</h4>
  {#if connection.residents.length === 0}
    <p class="text-sm text-muted-foreground">There are no residents in this account yet.</p>
  {:else}
    <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
      {#each connection.residents as resident (resident.id)}
        {@const updating = residentAccessUpdating[residentAccessKey(connection, resident)]}
        {@const transition = residentTransition(resident)}
        <div class="flex items-center justify-between gap-4 rounded-lg border bg-background px-3 py-2.5">
          <div class="min-w-0">
            <label class="block truncate text-sm font-medium" for={`${connection.id}-${resident.id}`}>
              {resident.name}
            </label>
            {#if transition}
              <p class="text-xs capitalize text-amber-700">{transition}</p>
            {/if}
          </div>
          <Switch
            id={`${connection.id}-${resident.id}`}
            checked={resident.enabled}
            disabled={updating ||
              (resident.enabled ? !connection.can_manage : !connection.can_provision) ||
              (!resident.enabled && connection.status !== 'connected')}
            onCheckedChange={(enabled) => toggleResidentAccess(connection, resident, enabled)}
            aria-label={`${resident.enabled ? 'Disable' : 'Enable'} ${connection.label} for ${resident.name}`} />
        </div>
      {/each}
    </div>
  {/if}
</div>

{#if tailnetResidents.length > 0}
  <div class="space-y-3 border-t pt-4" data-testid="tailnet-sign-ins">
    <div>
      <h4 class="text-sm font-semibold">On your tailnet</h4>
      <p class="text-xs text-muted-foreground">
        Each resident is its own Tailscale machine and joins once, by a sign-in from here. A resident that was just
        switched on picks it up when its container next restarts.
      </p>
    </div>
    {#each tailnetResidents as resident (resident.id)}
      <div class="space-y-2">
        <p class="text-sm font-medium">{resident.name}</p>
        <TailnetAccess url={resident.tailnet_url} agentName={resident.name} compact pageUrl={resident.integrations_url} />
      </div>
    {/each}
  </div>
{/if}
