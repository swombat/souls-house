<script>
  // Connections other houses share with this resident as their guest
  // (JWblqj): what was offered, by whom, with what authority, and where the
  // request stands. Owners approve, decline or revoke here.
  import { serviceIconClass } from '$lib/service-presentation';
  import ServiceIcon from '$lib/components/service-icon.svelte';
  import { CheckCircle } from 'phosphor-svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { authorityDescription } from '$lib/connection-authority';

  // `waiting` renders the requests still needing a decision, which
  // AgentIntegrationsPanel puts above the resident's own integrations so they
  // are the first thing an owner sees (Daniel, 2026-11-02, JVvkmJ); once
  // decided, a connection drops back to the list at the bottom.
  let { agent, sharedConnections = [], canDecideGuestAccess = false, waiting = false } = $props();
  let deciding = $state({});

  // The home's answer to another house's offer (JWblqj). Approve and decline
  // name the request they saw; the server refuses a stale one.
  function decide(connection, decision) {
    if (
      decision === 'revoke' &&
      !confirm(
        `Revoke ${connection.label} from ${connection.shared_from}? ${connection.shared_from} would need a new approval to share it again.`
      )
    )
      return;
    deciding = { ...deciding, [connection.id]: true };
    router.patch(
      connection.decision_url,
      { decision, generation: connection.home_approval_generation },
      {
        preserveScroll: true,
        onFinish() {
          const next = { ...deciding };
          delete next[connection.id];
          deciding = next;
        },
      }
    );
  }

  function sharedStatus(connection) {
    switch (connection.home_approval) {
      case 'pending':
        return `${connection.shared_from} wants to share this with ${agent.name}.`;
      case 'approved':
        return `Approved by ${connection.home_approval_by_name || 'this house'}${connection.home_approval_at ? ` on ${formatDay(connection.home_approval_at)}` : ''}.`;
      case 'declined':
        return 'Declined here. The sharing house can ask again.';
      case 'revoked':
        return 'Revoked here. The sharing house would need a new approval.';
      case 'withdrawn':
        return `${connection.shared_from} switched it off.`;
      case 'expired':
        return 'The request expired unanswered.';
      default:
        return '';
    }
  }

  function formatDay(iso) {
    const date = new Date(iso);
    return Number.isNaN(date.getTime()) ? '' : date.toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
  }
</script>

{#if sharedConnections.length > 0}
  <div class="space-y-3" data-testid={waiting ? 'shared-awaiting-approval' : 'shared-from-other-houses'}>
    <div>
      {#if waiting}
        <h3 class="text-lg font-semibold">Access approval needed</h3>
        <p class="text-sm text-muted-foreground">
          Another house wants to share {sharedConnections.length === 1 ? 'a connection' : 'connections'} with {agent.name},
          where it is a guest. Nothing is shared until an owner here approves. {agent.name} is one mind: what it reads there
          it can recall anywhere it speaks, including here.
        </p>
      {:else}
        <h3 class="text-lg font-semibold">Shared from other houses</h3>
        <p class="text-sm text-muted-foreground">
          Connections offered to {agent.name} where it is a guest. Nothing is shared until an owner here approves it.
          {agent.name} is one mind: what it reads there it can recall anywhere it speaks, including here. Ending it stops
          new access at once; a token already issued stays valid until it expires (about an hour for Google).
        </p>
      {/if}
    </div>
    <div class={`divide-y rounded-lg border ${waiting ? 'border-amber-500/40' : ''}`}>
      {#each sharedConnections as connection (connection.id)}
        <div class="space-y-3 p-5" data-testid="shared-connection" data-home-approval={connection.home_approval}>
          <div class="flex items-center gap-4">
            <div
              class={`flex size-11 shrink-0 items-center justify-center rounded-xl ${serviceIconClass(connection.provider)}`}>
              <ServiceIcon provider={connection.provider} size={24} />
            </div>
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="font-semibold">{connection.label}</h3>
                <span class="rounded-full bg-muted px-2 py-0.5 text-xs">via {connection.shared_from}</span>
                {#if connection.effective}
                  <span
                    class="inline-flex items-center gap-1 rounded-full bg-emerald-500/10 px-2 py-0.5 text-xs font-medium text-emerald-700">
                    <CheckCircle size={13} weight="fill" /> In use
                  </span>
                {/if}
              </div>
              <p class="text-sm text-muted-foreground">
                {connection.provider_name} · {connection.identity} · shared by {connection.shared_by}
              </p>
              <p class="mt-1 text-xs text-muted-foreground">
                Authority: {authorityDescription(connection)}{connection.can_send ? '; can send as the owner' : ''}
              </p>
              {#each connection.authority_warnings || [] as warning}
                <p class="mt-1 text-xs text-amber-700">{warning}</p>
              {/each}
              <p
                class={`mt-1 text-sm ${connection.home_approval === 'pending' ? 'text-amber-700' : 'text-muted-foreground'}`}
                data-testid="shared-status">
                {sharedStatus(connection)}
              </p>
            </div>
          </div>
          {#if connection.home_approval === 'pending'}
            <div class="flex flex-wrap gap-2">
              <Button
                type="button"
                disabled={!canDecideGuestAccess || deciding[connection.id]}
                onclick={() => decide(connection, 'approve')}>
                Approve
              </Button>
              <Button
                type="button"
                variant="outline"
                disabled={!canDecideGuestAccess || deciding[connection.id]}
                onclick={() => decide(connection, 'decline')}>
                Decline
              </Button>
              {#if !canDecideGuestAccess}
                <p class="self-center text-xs text-muted-foreground">Only an owner of this account can decide.</p>
              {/if}
            </div>
          {:else if connection.home_approval === 'approved' && connection.enabled}
            <Button
              type="button"
              variant="outline"
              class="border-destructive/20 text-destructive shadow-none hover:bg-destructive/10 hover:text-destructive"
              disabled={!canDecideGuestAccess || deciding[connection.id]}
              onclick={() => decide(connection, 'revoke')}>
              Revoke
            </Button>
          {/if}
        </div>
      {/each}
    </div>
  </div>
{/if}
