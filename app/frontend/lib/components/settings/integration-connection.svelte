<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { DropboxLogo, GithubLogo, Funnel, Bug, ShareNetwork, GoogleLogo, Heartbeat } from 'phosphor-svelte';
  import { serviceIconClass } from '$lib/service-presentation';
  import ConnectionGoogleAuthority from './connection-google-authority.svelte';
  import ConnectionResidentAccess from './connection-resident-access.svelte';
  let { connection, services, account } = $props();
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
            : connection.provider === 'tailscale'
              ? `Disconnect ${connection.label}? Residents leave the tailnet when they are next rebuilt, which can wait for an active turn. To cut access now, remove their nodes in the Tailscale admin console; revoke the auth key there too.`
              : `Disconnect ${connection.label}?`;
    if (confirm(warning)) {
      router.delete(`/accounts/${account.id}/service_connections/${connection.id}`);
    }
  }
</script>

<article class="overflow-hidden rounded-xl border bg-card shadow-sm">
  <div class="space-y-5 p-5 sm:p-6">
    <header class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
      <div class="flex min-w-0 items-center gap-4">
        <div
          class={`flex size-12 shrink-0 items-center justify-center rounded-xl ${serviceIconClass(connection.provider)}`}>
          {#if connection.provider === 'dropbox'}
            <DropboxLogo size={26} weight="fill" />
          {:else if connection.provider === 'google_workspace'}
            <GoogleLogo size={26} weight="bold" />
          {:else if connection.provider === 'github'}
            <GithubLogo size={26} weight="fill" />
          {:else if connection.provider === 'pipedrive'}
            <Funnel size={26} weight="bold" />
          {:else if connection.provider === 'honeybadger'}
            <Bug size={26} weight="bold" />
          {:else if connection.provider === 'tailscale'}
            <ShareNetwork size={26} weight="bold" />
          {:else}
            <Heartbeat size={26} weight="fill" />
          {/if}
        </div>
        <div class="min-w-0">
          <h3 class="truncate text-lg font-semibold">
            {connection.provider === 'google_workspace' ? connection.identity : connection.label}
          </h3>
          <p class="flex flex-wrap items-center gap-x-2 gap-y-1 text-sm text-muted-foreground">
            <span
              class={`rounded-full px-2 py-0.5 text-xs font-medium ${
                connection.management_scope === 'personal'
                  ? 'bg-sky-100 text-sky-800 dark:bg-sky-950 dark:text-sky-200'
                  : 'bg-violet-100 text-violet-800 dark:bg-violet-950 dark:text-violet-200'
              }`}>
              {connection.management_scope === 'personal' ? 'Personal' : 'Account'}
            </span>
            <span class="truncate">Connected by {connection.connected_by_name}</span>
          </p>
          {#if connection.status === 'reauthorizing'}
            <p class="text-sm text-amber-700">Reauthorization required before residents can use this connection.</p>
          {:else if connection.status === 'pairing'}
            <p class="text-sm text-amber-700">Waiting for pairing. Residents can use this once it is linked.</p>
          {/if}
        </div>
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
    </header>

    <ConnectionGoogleAuthority {connection} {services} {account} />

    <ConnectionResidentAccess {connection} />
    <div class="flex flex-col gap-3 border-t pt-4 sm:flex-row sm:items-center sm:gap-8">
      <label class="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={connection.enabled_for_new_agents}
          disabled={!connection.can_manage}
          onchange={(event) => updateConnection(connection, { enabled_for_new_agents: event.currentTarget.checked })} />
        Turn on for new residents automatically
      </label>
      {#if connection.can_delegate}
        <label class="flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            checked={connection.freely_provisionable}
            onchange={(event) => updateConnection(connection, { freely_provisionable: event.currentTarget.checked })} />
          Let account admins switch this on for residents
        </label>
      {/if}
    </div>
  </div>
</article>
