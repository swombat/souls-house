<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { DropboxLogo, GoogleLogo, ArrowLeft, CheckCircle } from 'phosphor-svelte';
  import { submitNativePost } from '$lib/integration-forms';
  import ServiceAuthoritySelector from '$lib/components/service-authority-selector.svelte';

  let { account, services = [], connections = [], can_manage = false } = $props();
  let selectedProfiles = $state({});
  let authoritySelections = $state({});
  let connectionAuthoritySelections = $state({});

  function profileFor(service) {
    return selectedProfiles[service.key] || service.access_profiles.find((profile) => profile.default)?.key;
  }

  function connect(service) {
    const data = {
      provider: service.key,
      management_scope: 'account_managed',
      access_profile: profileFor(service),
    };
    if (service.authority_groups.length > 0) {
      data.authority_selection = JSON.stringify(authorityFor(service));
      delete data.access_profile;
    }
    submitNativePost(`/accounts/${account.id}/service_authorizations`, data);
  }

  function authorityFor(service) {
    return (
      authoritySelections[service.key] ||
      Object.fromEntries(service.authority_groups.map((group) => [group.key, group.default]))
    );
  }

  function updateAuthority(service, selection) {
    authoritySelections = { ...authoritySelections, [service.key]: selection };
  }

  function hasAuthority(service) {
    return Object.values(authorityFor(service)).some((value) => value !== 'none');
  }

  function connectionAuthority(connection) {
    return connectionAuthoritySelections[connection.id] || connection.effective_authority || {};
  }

  function updateConnectionAuthority(connection, selection) {
    connectionAuthoritySelections = { ...connectionAuthoritySelections, [connection.id]: selection };
  }

  function reconnectGoogle(connection, service) {
    if (!confirm('Changing Google access temporarily disconnects it from residents while you consent again. Continue?'))
      return;
    submitNativePost(`/accounts/${account.id}/service_authorizations`, {
      provider: service.key,
      management_scope: connection.management_scope,
      service_connection_id: connection.id,
      authority_selection: JSON.stringify(connectionAuthority(connection)),
    });
  }

  function serviceFor(connection) {
    return services.find((service) => service.key === connection.provider);
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
              {#if service.authority_groups.length > 0}
                <ServiceAuthoritySelector
                  {service}
                  selection={authorityFor(service)}
                  onchange={(selection) => updateAuthority(service, selection)} />
              {:else}
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
              {/if}
            </div>
          </div>
          <Button
            type="button"
            disabled={!can_manage || (service.authority_groups.length > 0 && !hasAuthority(service))}
            onclick={() => connect(service)}>Connect {service.name}</Button>
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
              <span
                class={connection.status === 'connected'
                  ? 'inline-flex items-center gap-1 text-xs text-emerald-700'
                  : 'inline-flex items-center gap-1 text-xs text-amber-700'}>
                <CheckCircle size={14} weight="fill" />
                {connection.status === 'connected' ? 'Connected' : 'Reauthorization required'}
              </span>
            </div>
            <p class="text-sm text-muted-foreground">{connection.identity}</p>
            {#if (connection.granted_scopes || []).length > 0}
              <p class="mt-2 text-xs">Granted scopes: {connection.granted_scopes.join(', ')}</p>
            {/if}
          </div>
          {#if connection.can_manage}
            <Button type="button" variant="destructive" onclick={() => disconnect(connection)}>Disconnect</Button>
          {/if}
        </div>
        {#if connection.provider === 'google_workspace'}
          {@const googleService = serviceFor(connection)}
          {#if googleService}
            <ServiceAuthoritySelector
              service={googleService}
              selection={connectionAuthority(connection)}
              disabled={!connection.can_manage}
              onchange={(selection) => updateConnectionAuthority(connection, selection)} />
            {#each connection.authority_warnings || [] as warning}
              <p class="text-xs text-amber-700">{warning}</p>
            {/each}
            {#if connection.can_manage}
              <Button type="button" variant="outline" onclick={() => reconnectGoogle(connection, googleService)}>
                {connection.status === 'reauthorizing' ? 'Finish reconnecting Google' : 'Edit Google access'}
              </Button>
            {/if}
          {/if}
        {/if}
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
