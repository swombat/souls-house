<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Switch } from '$lib/components/shadcn/switch/index.js';
  import { DropboxLogo, GithubLogo, GoogleLogo, Heartbeat, ArrowLeft } from 'phosphor-svelte';
  import { submitNativePost } from '$lib/integration-forms';
  import ServiceAuthoritySelector from '$lib/components/service-authority-selector.svelte';

  let { account, services = [], connections = [], focused_service: focusedService = null } = $props();
  let selectedProfiles = $state({});
  let authoritySelections = $state({});
  let connectionAuthoritySelections = $state({});
  let credentialValues = $state({});
  let residentAccessUpdating = $state({});
  let editingConnections = $state({});

  function profileFor(service) {
    return selectedProfiles[service.key] || service.access_profiles.find((profile) => profile.default)?.key;
  }

  function connect(service) {
    const data = {
      provider: service.key,
      management_scope: 'personal',
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

  function credentialsFor(service) {
    return credentialValues[service.key] || {};
  }

  function updateCredential(service, field, value) {
    credentialValues = {
      ...credentialValues,
      [service.key]: {
        ...credentialsFor(service),
        [field.key]: value,
      },
    };
  }

  function connectCredentials(service) {
    router.post(`/accounts/${account.id}/service_connections`, {
      provider: service.key,
      management_scope: 'personal',
      credentials: credentialsFor(service),
    });
  }

  function serviceDescription(service) {
    if (service.key === 'dropbox') return 'Files and folders, with provider-enforced scope choices.';
    if (service.key === 'google_workspace')
      return 'Gmail, Calendar, Drive, Docs, Sheets, Slides, and Meet through the Google Workspace gws client.';
    if (service.key === 'oura') return 'Sleep, readiness, activity, and direct Oura API access.';
    if (service.key === 'github') return 'Repository-scoped access using a fine-grained personal access token.';
    return 'Direct external-service access for selected residents.';
  }

  function serviceIconClass(serviceKey) {
    if (serviceKey === 'dropbox') return 'bg-blue-600 text-white';
    if (serviceKey === 'google_workspace') return 'bg-green-600 text-white';
    if (serviceKey === 'github') return 'bg-neutral-900 text-white';
    return 'bg-red-500 text-white';
  }

  function shortScope(scope) {
    return scope
      .replace('https://www.googleapis.com/auth/', '')
      .replace('https://mail.google.com/', 'mail')
      .replace('https://www.googleapis.com/', '');
  }

  function visibleScopes(connection) {
    return (connection.granted_scopes || [])
      .map(shortScope)
      .filter((scope) => !['openid', 'userinfo.email', 'email'].includes(scope));
  }

  function editingConnection(connection) {
    return editingConnections[connection.id] || connection.status === 'reauthorizing';
  }

  function editConnection(connection) {
    editingConnections = { ...editingConnections, [connection.id]: true };
  }

  function cancelEditingConnection(connection) {
    const next = { ...editingConnections };
    delete next[connection.id];
    editingConnections = next;
    const selections = { ...connectionAuthoritySelections };
    delete selections[connection.id];
    connectionAuthoritySelections = selections;
  }

  function residentTransition(resident) {
    if (resident.provisioning_status === 'pending') return 'Adding…';
    if (resident.provisioning_status === 'removal_pending') return 'Removing…';
    if (resident.provisioning_status && resident.provisioning_status !== 'provisioned') {
      return resident.provisioning_status.replaceAll('_', ' ');
    }
    return null;
  }

  function updateConnection(connection, attributes) {
    router.patch(`/accounts/${account.id}/service_connections/${connection.id}`, {
      service_connection: attributes,
    });
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

<svelte:head><title>Personal Services</title></svelte:head>

<div class="container mx-auto max-w-6xl space-y-8 p-8">
  {#if focusedService}
    <a
      href={`/accounts/${account.id}/personal_services`}
      class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
      <ArrowLeft size={16} /> Personal Services
    </a>
    <div class="max-w-2xl space-y-6">
      <div>
        <h1 class="text-3xl font-bold">Connect {focusedService.name}</h1>
        <p class="mt-2 text-muted-foreground">{serviceDescription(focusedService)}</p>
      </div>
      <div class="space-y-5 rounded-xl border bg-card p-6 shadow-sm">
        <div class="flex items-center gap-4">
          <div class={`flex size-12 items-center justify-center rounded-xl ${serviceIconClass(focusedService.key)}`}>
            {#if focusedService.key === 'dropbox'}
              <DropboxLogo size={26} weight="fill" />
            {:else if focusedService.key === 'google_workspace'}
              <GoogleLogo size={26} weight="bold" />
            {:else if focusedService.key === 'github'}
              <GithubLogo size={26} weight="fill" />
            {:else}
              <Heartbeat size={26} weight="fill" />
            {/if}
          </div>
          <h2 class="text-xl font-semibold">{focusedService.name}</h2>
        </div>

        {#if focusedService.connection_method === 'credentials'}
          <div class="space-y-4">
            {#if focusedService.key === 'github'}
              <div class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
                <a
                  href="https://github.com/settings/personal-access-tokens/new"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-medium text-primary underline underline-offset-4">
                  Create a fine-grained token on GitHub
                </a>
                with access to one repository and only the permissions it needs.
              </div>
            {/if}
            {#each focusedService.credential_fields as field}
              <label class="block space-y-1.5">
                <span class="text-sm font-medium">{field.label}</span>
                <input
                  type={field.type || 'text'}
                  value={credentialsFor(focusedService)[field.key] || ''}
                  placeholder={field.placeholder || ''}
                  autocomplete={field.type === 'password' ? 'off' : 'on'}
                  class="w-full rounded-md border bg-background px-3 py-2 text-sm"
                  oninput={(event) => updateCredential(focusedService, field, event.currentTarget.value)} />
                {#if field.help}<span class="block text-xs text-muted-foreground">{field.help}</span>{/if}
              </label>
            {/each}
          </div>
        {:else if focusedService.authority_groups.length > 0}
          <ServiceAuthoritySelector
            service={focusedService}
            selection={authorityFor(focusedService)}
            onchange={(selection) => updateAuthority(focusedService, selection)} />
        {:else if focusedService.access_profiles.length > 1}
          <select
            class="w-full rounded-md border bg-background px-3 py-2 text-sm"
            value={profileFor(focusedService)}
            onchange={(event) =>
              (selectedProfiles = { ...selectedProfiles, [focusedService.key]: event.currentTarget.value })}>
            {#each focusedService.access_profiles as profile}
              <option value={profile.key}>{profile.name}{profile.default ? ' — safest default' : ''}</option>
            {/each}
          </select>
        {/if}

        <div class="flex justify-end gap-3 border-t pt-4">
          <Button variant="outline" href={`/accounts/${account.id}/personal_services`}>Cancel</Button>
          <Button
            type="button"
            disabled={focusedService.authority_groups.length > 0 && !hasAuthority(focusedService)}
            onclick={() =>
              focusedService.connection_method === 'credentials'
                ? connectCredentials(focusedService)
                : connect(focusedService)}>
            Connect {focusedService.name}
          </Button>
        </div>
      </div>
    </div>
  {:else}
    <a href="/user/edit" class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
      <ArrowLeft size={16} /> User settings
    </a>
    <div>
      <h1 class="text-3xl font-bold">Personal Services</h1>
      <p class="mt-2 text-muted-foreground">
        Connect your own external identities to {account.name}, then choose which residents may use them.
      </p>
    </div>

    <section class="space-y-3 rounded-xl border bg-muted/20 p-4">
      <h2 class="text-sm font-semibold">Connect new…</h2>
      <div class="flex flex-wrap gap-2">
        {#each services as service}
          <Button variant="outline" href={`/accounts/${account.id}/personal_services?connect=${service.key}`}>
            {#if service.key === 'dropbox'}
              <DropboxLogo weight="fill" />
            {:else if service.key === 'google_workspace'}
              <GoogleLogo weight="bold" />
            {:else if service.key === 'github'}
              <GithubLogo weight="fill" />
            {:else}
              <Heartbeat weight="fill" />
            {/if}
            {service.name}
          </Button>
        {/each}
      </div>
      <p class="text-xs text-muted-foreground">
        You can connect more than one service of the same kind—for example, several GitHub repositories or Google
        accounts.
      </p>
    </section>

    <section class="space-y-4">
      <div>
        <h2 class="text-xl font-semibold">Connected services</h2>
        <p class="text-sm text-muted-foreground">Manage each connection and choose which residents can use it.</p>
      </div>
      {#if connections.length === 0}
        <p class="rounded-xl border bg-card p-6 text-sm text-muted-foreground">
          No personal services are connected yet.
        </p>
      {/if}
      {#each connections as connection}
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
                    <p class="text-sm text-amber-700">
                      Reauthorization required before residents can use this connection.
                    </p>
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

            {#if connection.provider === 'google_workspace'}
              {@const googleService = serviceFor(connection)}
              <div class="space-y-3">
                {#if visibleScopes(connection).length > 0}
                  <div class="flex flex-wrap gap-1.5">
                    {#each visibleScopes(connection) as scope}
                      <span class="rounded-full bg-muted px-2.5 py-1 font-mono text-xs">{scope}</span>
                    {/each}
                  </div>
                {/if}
                {#each connection.authority_warnings || [] as warning}
                  <p class="text-xs text-amber-700">{warning}</p>
                {/each}
                {#if googleService && connection.can_manage}
                  {#if editingConnection(connection)}
                    <div class="space-y-4 rounded-lg border bg-muted/20 p-4">
                      <ServiceAuthoritySelector
                        service={googleService}
                        selection={connectionAuthority(connection)}
                        onchange={(selection) => updateConnectionAuthority(connection, selection)} />
                      <div class="flex justify-end gap-2">
                        {#if connection.status !== 'reauthorizing'}
                          <Button
                            type="button"
                            variant="ghost"
                            size="sm"
                            onclick={() => cancelEditingConnection(connection)}>
                            Cancel
                          </Button>
                        {/if}
                        <Button type="button" size="sm" onclick={() => reconnectGoogle(connection, googleService)}>
                          {connection.status === 'reauthorizing' ? 'Finish reconnecting' : 'Save and reconnect'}
                        </Button>
                      </div>
                    </div>
                  {:else}
                    <Button type="button" variant="outline" size="sm" onclick={() => editConnection(connection)}>
                      Edit access
                    </Button>
                  {/if}
                {/if}
              </div>
            {/if}

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
                        disabled={updating || (!resident.enabled && connection.status !== 'connected')}
                        onCheckedChange={(enabled) => toggleResidentAccess(connection, resident, enabled)}
                        aria-label={`${resident.enabled ? 'Disable' : 'Enable'} ${connection.label} for ${resident.name}`} />
                    </div>
                  {/each}
                </div>
              {/if}
            </div>

            <div class="flex flex-col gap-3 border-t pt-4 sm:flex-row sm:items-center sm:gap-8">
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={connection.enabled_for_new_agents}
                  onchange={(event) =>
                    updateConnection(connection, { enabled_for_new_agents: event.currentTarget.checked })} />
                Provision to new residents by default
              </label>
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  checked={connection.freely_provisionable}
                  onchange={(event) =>
                    updateConnection(connection, { freely_provisionable: event.currentTarget.checked })} />
                Allow account admins to provision this access
              </label>
            </div>
          </div>
        </article>
      {/each}
    </section>
  {/if}
</div>
