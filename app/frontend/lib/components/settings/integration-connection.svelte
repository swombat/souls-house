<script>
  import ServiceIcon from '$lib/components/service-icon.svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { serviceIconClass } from '$lib/service-presentation';
  import ConnectionGoogleAuthority from './connection-google-authority.svelte';
  import ConnectionRepositories from './connection-repositories.svelte';
  import ConnectionResidentAccess from './connection-resident-access.svelte';
  import ConnectionTelegramLogin from './connection-telegram-login.svelte';
  import ConnectionTelegramStatus from './connection-telegram-status.svelte';
  import ConnectionWhatsappPairing from './connection-whatsapp-pairing.svelte';
  import ConnectionWhatsappStatus from './connection-whatsapp-status.svelte';
  import { accessSummary, attentionLabel, connectionTitle } from '$lib/connection-summary';
  import { CaretDown, UsersThree, WarningCircle } from 'phosphor-svelte';
  let { connection, services, account, open = false, onToggle = () => {} } = $props();
  let title = $derived(connectionTitle(connection));
  let summary = $derived(accessSummary(connection));
  let attention = $derived(attentionLabel(connection));
  let panelId = $derived(`connection-${connection.id}-details`);
  function updateConnection(connection, attributes) {
    router.patch(`/accounts/${account.id}/service_connections/${connection.id}`, {
      service_connection: attributes,
    });
  }

  function removeConnection(connection) {
    const warning =
      connection.provider === 'github'
        ? `Disconnect ${connection.label}? This removes the token from residents but does not revoke it on GitHub.`
        : connection.provider === 'pipedrive'
          ? `Disconnect ${connection.label}? This removes the token from residents. To revoke it, regenerate your API token in Pipedrive.`
          : connection.provider === 'honeybadger'
            ? `Disconnect ${connection.label}? This removes the token from residents. To revoke it, reset your personal auth token in Honeybadger.`
            : connection.provider === 'porkbun'
              ? `Disconnect ${connection.label}? This removes the keys from residents. To revoke them, delete the key under Account → API Access in Porkbun.`
              : connection.provider === 'twitterapi_io'
                ? `Disconnect ${connection.label}? The tweet stream then carries on paid by another TwitterAPI.io integration on this account if there is one, or by the house key if the house has lent it to this account; otherwise collection stops. To revoke the key, regenerate it on twitterapi.io.`
                : connection.provider === 'cloudflare'
                  ? `Disconnect ${connection.label}? This removes the token from residents. To revoke it, roll or delete the token under My Profile → API Tokens in Cloudflare.`
                  : connection.provider === 'tailscale'
                    ? `Disconnect ${connection.label}? Residents leave the tailnet when they are next rebuilt, which can wait for an active turn. To cut access now, remove their nodes in the Tailscale admin console; revoke the auth key there too.`
                    : `Disconnect ${connection.label}?`;
    if (confirm(warning)) {
      router.delete(`/accounts/${account.id}/service_connections/${connection.id}`);
    }
  }
</script>

<article
  class="overflow-hidden rounded-xl border bg-card shadow-sm"
  data-provider={connection.provider}
  data-status={connection.status}>
  <div class="relative flex items-center gap-3 p-4 sm:gap-4 sm:px-5">
    <button
      type="button"
      class="absolute inset-0 rounded-xl transition hover:bg-muted/40 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-ring"
      aria-expanded={open}
      aria-controls={panelId}
      aria-label={`${open ? 'Hide' : 'Show'} details for ${title}`}
      onclick={onToggle}></button>
    <div
      class={`pointer-events-none relative flex size-10 shrink-0 items-center justify-center rounded-lg ${serviceIconClass(connection.provider)}`}>
      <ServiceIcon provider={connection.provider} size={22} />
    </div>
    <div class="pointer-events-none relative min-w-0 flex-1 space-y-1">
      <h3 class="line-clamp-2 break-words font-semibold leading-snug">{title}</h3>
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm">
        <span
          class={`shrink-0 rounded-full px-2 py-0.5 text-xs font-medium ${
            connection.management_scope === 'personal'
              ? 'bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-200'
              : 'bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-200'
          }`}>
          {connection.management_scope === 'personal' ? 'Personal' : 'Account'}
        </span>
        {#if attention}
          <span
            class="inline-flex shrink-0 items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-900 dark:bg-amber-950 dark:text-amber-200"
            data-testid="connection-attention">
            <WarningCircle size={14} weight="bold" />
            {attention}
          </span>
        {/if}
        <span
          class={`inline-flex min-w-0 items-center gap-1.5 ${summary.none ? 'italic text-muted-foreground/80' : 'text-muted-foreground'}`}
          data-testid="connection-access-summary">
          <UsersThree size={16} class="shrink-0" />
          <span class="break-words">{summary.text}</span>
        </span>
      </div>
    </div>
    <CaretDown
      size={18}
      class={`pointer-events-none relative shrink-0 text-muted-foreground transition-transform ${open ? 'rotate-180' : ''}`} />
  </div>

  {#if open}
    <div id={panelId} class="space-y-5 border-t px-4 pb-5 pt-4 sm:px-6">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0 space-y-1">
          <p class="truncate text-sm text-muted-foreground">Connected by {connection.connected_by_name}</p>
          {#if connection.status === 'reauthorizing' && connection.provider === 'whatsapp'}
            <p class="text-sm text-amber-700">Pair again before residents can use this connection.</p>
          {:else if connection.status === 'reauthorizing'}
            <p class="text-sm text-amber-700">Reauthorization required before residents can use this connection.</p>
          {:else if connection.status === 'pairing' && connection.provider === 'telegram'}
            <p class="text-sm text-amber-700">Waiting for sign-in. Residents can use this once it is signed in.</p>
          {:else if connection.status === 'pairing'}
            <p class="text-sm text-amber-700">Waiting for pairing. Residents can use this once it is linked.</p>
          {:else if connection.status === 'revoked' && connection.comms?.unpair_pending}
            <p class="text-sm text-amber-700" data-testid="unpair-pending">
              Disconnected here, but the WhatsApp connector has not yet confirmed removing the linked device. The house
              keeps trying. To remove it now, open WhatsApp on your phone: Settings, Linked devices.
            </p>
          {/if}
        </div>
        {#if connection.can_manage}
          <Button
            type="button"
            variant="outline"
            size="sm"
            class="border-destructive/20 text-destructive shadow-none hover:bg-destructive/10 hover:text-destructive"
            onclick={() => removeConnection(connection)}>
            Disconnect
          </Button>
        {:else}
          <p class="text-sm text-muted-foreground sm:text-right">Managed by account admins</p>
        {/if}
      </div>

      <ConnectionGoogleAuthority {connection} {services} {account} />

      {#if connection.provider === 'telegram'}
        {#if connection.status === 'pairing' || connection.status === 'reauthorizing'}
          <ConnectionTelegramLogin {connection} {account} />
          {#if connection.can_delegate}
            <a
              class="text-sm text-muted-foreground underline"
              href={`/accounts/${account.id}/service_connections/${connection.id}/login`}
              data-testid="telegram-sign-in-page-link">
              Open the sign-in on its own page
            </a>
          {/if}
        {:else if connection.status === 'connected'}
          <ConnectionTelegramStatus {connection} {account} />
        {/if}
      {:else if connection.provider === 'whatsapp'}
        {#if ['pairing', 'reauthorizing', 'error'].includes(connection.status)}
          <ConnectionWhatsappPairing {connection} {account} />
        {:else if connection.status === 'connected'}
          <ConnectionWhatsappStatus {connection} />
        {/if}
      {/if}

      <ConnectionResidentAccess {connection} />
      {#if connection.provider === 'github' && connection.repositories}
        <ConnectionRepositories {connection} />
      {/if}
      <div class="flex flex-col gap-3 border-t pt-4 sm:flex-row sm:items-center sm:gap-8">
        <label class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={connection.enabled_for_new_agents}
            disabled={!connection.can_manage}
            onchange={(event) =>
              updateConnection(connection, { enabled_for_new_agents: event.currentTarget.checked })} />
          Turn on for new residents automatically
        </label>
        {#if connection.can_delegate}
          <label class="flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              checked={connection.freely_provisionable}
              onchange={(event) =>
                updateConnection(connection, { freely_provisionable: event.currentTarget.checked })} />
            Let account admins switch this on for residents
          </label>
        {/if}
      </div>
    </div>
  {/if}
</article>
