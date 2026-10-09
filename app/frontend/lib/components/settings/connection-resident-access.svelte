<script>
  import { router } from '@inertiajs/svelte';
  import { Switch } from '$lib/components/shadcn/switch';
  let { connection } = $props();
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

  // Sending as the owner (WhatsApp): only the owner can switch it on; anyone
  // who manages the connection can switch it off.
  function toggleSendGrant(connection, resident, canSend) {
    const key = `${residentAccessKey(connection, resident)}:send`;
    residentAccessUpdating = { ...residentAccessUpdating, [key]: true };
    router.patch(
      resident.send_grant_url,
      { can_send: canSend },
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
  {#if connection.comms_sends_url}
    <!-- Owner only: the controller sets comms_sends_url for the owner alone. -->
    <p class="text-xs text-muted-foreground">
      <a class="underline" href={connection.comms_sends_url} target="_blank" rel="noopener">
        What residents sent as you, and who allowed it
      </a>
    </p>
  {/if}
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
            {#if resident.send_grant_url && resident.enabled}
              <label class="mt-1 flex items-center gap-1.5 text-xs text-muted-foreground">
                <input
                  type="checkbox"
                  checked={resident.can_send}
                  disabled={residentAccessUpdating[`${residentAccessKey(connection, resident)}:send`] ||
                    (resident.can_send ? !connection.can_manage : !connection.can_grant_send) ||
                    (!resident.can_send && connection.status !== 'connected')}
                  onchange={(event) => toggleSendGrant(connection, resident, event.currentTarget.checked)} />
                Can send as you
              </label>
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
