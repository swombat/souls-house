<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { DropboxLogo, GithubLogo, GoogleLogo, Heartbeat } from 'phosphor-svelte';
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
          {:else}
            <Heartbeat size={26} weight="fill" />
          {/if}
        </div>
        <div class="min-w-0">
          <h3 class="truncate text-lg font-semibold">
            {connection.provider === 'google_workspace' ? connection.identity : connection.label}
          </h3>
          {#if connection.status === 'reauthorizing'}
            <p class="text-sm text-amber-700">Reauthorization required before residents can use this connection.</p>
          {/if}
        </div>
      </div>
      <Button
        type="button"
        variant="outline"
        size="sm"
        class="border-destructive/20 text-destructive shadow-none hover:bg-destructive/10 hover:text-destructive"
        onclick={() => removeConnection(connection)}>
        Disconnect
      </Button>
    </header>

    <ConnectionGoogleAuthority {connection} {services} {account} />

    <ConnectionResidentAccess {connection} />
    <div class="flex flex-col gap-3 border-t pt-4 sm:flex-row sm:items-center sm:gap-8">
      <label class="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={connection.enabled_for_new_agents}
          onchange={(event) => updateConnection(connection, { enabled_for_new_agents: event.currentTarget.checked })} />
        Provision to new residents by default
      </label>
      <label class="flex items-center gap-2 text-sm">
        <input
          type="checkbox"
          checked={connection.freely_provisionable}
          onchange={(event) => updateConnection(connection, { freely_provisionable: event.currentTarget.checked })} />
        Allow account admins to provision this access
      </label>
    </div>
  </div>
</article>
