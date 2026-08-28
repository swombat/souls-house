<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { DropboxLogo, GoogleLogo, ArrowLeft, CheckCircle } from 'phosphor-svelte';
  import { submitNativePost } from '$lib/integration-forms';

  let { account, services = [], connections = [], can_manage = false } = $props();
  let selectedProfiles = $state({});

  function profileFor(service) {
    return selectedProfiles[service.key] || service.access_profiles.find((profile) => profile.default)?.key;
  }

  function connect(service) {
    submitNativePost(`/accounts/${account.id}/service_authorizations`, {
      provider: service.key,
      management_scope: 'account_managed',
      access_profile: profileFor(service),
    });
  }

  function updateConnection(connection, attributes) {
    router.patch(`/accounts/${account.id}/service_connections/${connection.id}`, {
      service_connection: attributes,
    });
  }

  function disconnect(connection) {
    if (confirm(`Disconnect ${connection.label}? Residents will lose this credential.`)) {
      router.delete(`/accounts/${account.id}/service_connections/${connection.id}`);
    }
  }
</script>

<svelte:head><title>Account Services</title></svelte:head>

<div class="container mx-auto max-w-5xl space-y-8 p-8">
  <a
    href={`/accounts/${account.id}`}
    class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
    <ArrowLeft size={16} /> Account settings
  </a>
  <div>
    <h1 class="text-3xl font-bold">Account Services</h1>
    <p class="mt-2 text-muted-foreground">
      Connect identities controlled by {account.name}. Selected residents receive the credential and call the provider
      directly.
    </p>
  </div>

  <section class="space-y-4">
    <h2 class="text-xl font-semibold">Available services</h2>
    {#each services as service}
      <div class="rounded-lg border p-5">
        <div class="flex flex-col gap-5 sm:flex-row sm:items-start sm:justify-between">
          <div class="flex gap-4">
            <div
              class={service.key === 'google_workspace'
                ? 'flex size-11 items-center justify-center rounded-xl bg-green-600 text-white'
                : 'flex size-11 items-center justify-center rounded-xl bg-blue-600 text-white'}>
              {#if service.key === 'google_workspace'}
                <GoogleLogo size={24} weight="bold" />
              {:else}
                <DropboxLogo size={24} weight="fill" />
              {/if}
            </div>
            <div>
              <h3 class="font-semibold">{service.name}</h3>
              <p class="text-sm text-muted-foreground">
                Shared account credentials, independently selectable per resident.
              </p>
              <select
                class="mt-3 rounded-md border bg-background px-3 py-2 text-sm"
                value={profileFor(service)}
                onchange={(event) =>
                  (selectedProfiles = { ...selectedProfiles, [service.key]: event.currentTarget.value })}>
                {#each service.access_profiles as profile}
                  <option value={profile.key}>{profile.name}{profile.default ? ' — safest default' : ''}</option>
                {/each}
              </select>
              <p class="mt-2 text-xs text-muted-foreground">
                Read-only is the default. Write and sharing authority must be chosen deliberately.
              </p>
            </div>
          </div>
          <Button type="button" disabled={!can_manage} onclick={() => connect(service)}>Connect {service.name}</Button>
        </div>
      </div>
    {/each}
  </section>

  <section class="space-y-4">
    <h2 class="text-xl font-semibold">Connected identities</h2>
    {#if connections.length === 0}
      <p class="rounded-lg border p-5 text-sm text-muted-foreground">No account-managed services are connected yet.</p>
    {/if}
    {#each connections as connection}
      <div class="space-y-4 rounded-lg border p-5">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <div class="flex items-center gap-2">
              <h3 class="font-semibold">{connection.label}</h3>
              <span class="inline-flex items-center gap-1 text-xs text-emerald-700"
                ><CheckCircle size={14} weight="fill" />Connected</span>
            </div>
            <p class="text-sm text-muted-foreground">{connection.identity}</p>
            <p class="mt-2 text-xs">Granted scopes: {connection.granted_scopes.join(', ')}</p>
          </div>
          {#if connection.can_manage}
            <Button type="button" variant="destructive" onclick={() => disconnect(connection)}>Disconnect</Button>
          {/if}
        </div>
        <label class="flex items-center gap-3 text-sm">
          <input
            type="checkbox"
            checked={connection.enabled_for_new_agents}
            disabled={!connection.can_manage}
            onchange={(event) =>
              updateConnection(connection, { enabled_for_new_agents: event.currentTarget.checked })} />
          Provision to newly created residents by default
        </label>
      </div>
    {/each}
  </section>
</div>
