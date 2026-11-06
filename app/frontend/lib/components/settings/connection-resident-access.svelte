<script>
  import { router } from '@inertiajs/svelte';
  import { Switch } from '$lib/components/shadcn/switch';
  import TailnetAccess from '$lib/components/agents/tailnet-access.svelte';
  // busy: true while any switch's save is in flight, so a page that offers
  // its own exit (the access step) can hold it until the save lands.
  let { connection, busy = $bindable(false) } = $props();
  // Tailscale: every granted resident is its own node and signs in once, here.
  let tailnetResidents = $derived(
    connection.provider === 'tailscale' ? connection.residents.filter((resident) => resident.tailnet_url) : []
  );
  let residentAccessUpdating = $state({});
  $effect(() => {
    busy = Object.values(residentAccessUpdating).some(Boolean);
  });
  function residentTransition(resident) {
    if (resident.guest && !resident.effective) return null;
    if (resident.provisioning_status === 'pending') return 'Adding…';
    if (resident.provisioning_status === 'removal_pending') return 'Removing…';
    if (resident.provisioning_status && resident.provisioning_status !== 'provisioned') {
      return resident.provisioning_status.replaceAll('_', ' ');
    }
    return null;
  }

  // Where a guest's grant stands with its home (JWblqj). The switch is the
  // sharing side's; approval is the home's; this line says which is waited on.
  function guestStatus(resident) {
    if (!resident.guest) return null;
    const home = `${resident.name}'s home`;
    switch (resident.home_approval) {
      case 'pending':
        return `Awaiting approval from ${home}`;
      case 'approved':
        return `Approved by ${resident.home_approval_by_name || home}${resident.home_approval_at ? ` on ${formatDay(resident.home_approval_at)}` : ''}`;
      case 'declined':
        return `Declined by ${home}. You can ask again.`;
      case 'revoked':
        return `Revoked by ${home}. Switching it on asks again.`;
      case 'expired':
        return 'The request expired unanswered. You can ask again.';
      default:
        return null;
    }
  }

  function formatDay(iso) {
    const date = new Date(iso);
    return Number.isNaN(date.getTime()) ? '' : date.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  }

  function canToggle(connection, resident) {
    if (resident.guest) return resident.enabled ? resident.can_withdraw : resident.can_share;
    return resident.enabled ? connection.can_manage : connection.can_provision;
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

  // Sending as the owner (comms): offered only where the house switched
  // sending on (the controller sends send_grant_url then). Only the owner
  // can switch it on; anyone who manages the connection can switch it off.
  function sendGrantKey(connection, resident) {
    return `${residentAccessKey(connection, resident)}:send`;
  }

  function toggleSendGrant(connection, resident, canSend) {
    const key = sendGrantKey(connection, resident);
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
    {#if connection.residents.some((resident) => resident.guest)}
      <p class="text-xs text-muted-foreground" data-testid="guest-sharing-note">
        A guest resident gets this only once its home approves. A resident is one mind: what it reads here as a guest it
        can recall wherever it speaks. Switching it off stops new access at once; a token already issued stays valid
        until it expires (about an hour for Google).
      </p>
    {/if}
    <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
      {#each connection.residents as resident (resident.id)}
        {@const updating = residentAccessUpdating[residentAccessKey(connection, resident)]}
        {@const transition = residentTransition(resident)}
        {@const guest = guestStatus(resident)}
        <div
          class="flex items-center justify-between gap-4 rounded-lg border bg-background px-3 py-2.5"
          data-guest={resident.guest ? 'true' : undefined}>
          <div class="min-w-0">
            <label class="block truncate text-sm font-medium" for={`${connection.id}-${resident.id}`}>
              {resident.name}
            </label>
            {#if resident.guest}
              <p class="text-xs text-muted-foreground" data-testid="guest-badge">
                guest · hosted in {resident.home_account_name}
              </p>
            {/if}
            {#if guest}
              <p
                class={`text-xs ${resident.home_approval === 'pending' ? 'text-amber-700' : 'text-muted-foreground'}`}
                data-testid="guest-approval">
                {guest}
              </p>
            {/if}
            {#if transition}
              <p class="text-xs capitalize text-amber-700">{transition}</p>
            {/if}
            {#if resident.send_grant_url && resident.enabled && (!resident.guest || resident.effective)}
              <label class="mt-1 flex items-center gap-1.5 text-xs text-muted-foreground">
                <input
                  type="checkbox"
                  checked={resident.can_send}
                  disabled={residentAccessUpdating[sendGrantKey(connection, resident)] ||
                    (resident.can_send ? !connection.can_manage : !connection.can_grant_send) ||
                    (!resident.can_send && connection.status !== 'connected')}
                  onchange={(event) => toggleSendGrant(connection, resident, event.currentTarget.checked)} />
                Can send as you{resident.guest ? ' (asks the home again)' : ''}
              </label>
            {/if}
          </div>
          <Switch
            id={`${connection.id}-${resident.id}`}
            checked={resident.enabled}
            disabled={updating ||
              !canToggle(connection, resident) ||
              (!resident.enabled && connection.status !== 'connected')}
            onCheckedChange={(enabled) => toggleResidentAccess(connection, resident, enabled)}
            aria-label={`${resident.enabled ? 'Disable' : resident.guest ? 'Share' : 'Enable'} ${connection.label} ${resident.guest ? 'with' : 'for'} ${resident.name}`} />
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
        <TailnetAccess
          url={resident.tailnet_url}
          agentName={resident.name}
          compact
          pageUrl={resident.integrations_url} />
      </div>
    {/each}
  </div>
{/if}
