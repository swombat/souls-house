<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { DropboxLogo, GithubLogo, GoogleLogo, Heartbeat, ArrowLeft } from 'phosphor-svelte';
  import { submitNativePost } from '$lib/integration-forms';

  let { account, services = [], connections = [] } = $props();
  let selectedProfiles = $state({});
  let credentialValues = $state({});

  function profileFor(service) {
    return selectedProfiles[service.key] || service.access_profiles.find((profile) => profile.default)?.key;
  }

  function connect(service) {
    submitNativePost(`/accounts/${account.id}/service_authorizations`, {
      provider: service.key,
      management_scope: 'personal',
      access_profile: profileFor(service),
    });
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

<svelte:head><title>Personal Services</title></svelte:head>

<div class="container mx-auto max-w-5xl space-y-8 p-8">
  <a href="/user/edit" class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
    <ArrowLeft size={16} /> User settings
  </a>
  <div>
    <h1 class="text-3xl font-bold">Personal Services</h1>
    <p class="mt-2 text-muted-foreground">
      Connect your own external identities to {account.name}, then choose which residents you trust with each
      credential.
    </p>
  </div>

  <section class="grid gap-4 md:grid-cols-2">
    {#each services as service}
      <div class="space-y-4 rounded-lg border p-5">
        <div class="flex gap-4">
          <div
            class={service.key === 'dropbox'
              ? 'flex size-11 items-center justify-center rounded-xl bg-blue-600 text-white'
              : service.key === 'google_workspace'
                ? 'flex size-11 items-center justify-center rounded-xl bg-green-600 text-white'
                : service.key === 'github'
                  ? 'flex size-11 items-center justify-center rounded-xl bg-neutral-900 text-white'
                  : 'flex size-11 items-center justify-center rounded-xl bg-red-500 text-white'}>
            {#if service.key === 'dropbox'}
              <DropboxLogo size={24} weight="fill" />
            {:else if service.key === 'google_workspace'}
              <GoogleLogo size={24} weight="bold" />
            {:else if service.key === 'github'}
              <GithubLogo size={24} weight="fill" />
            {:else}
              <Heartbeat size={24} weight="fill" />
            {/if}
          </div>
          <div>
            <h3 class="font-semibold">{service.name}</h3>
            <p class="text-sm text-muted-foreground">
              {serviceDescription(service)}
            </p>
          </div>
        </div>
        {#if service.connection_method === 'credentials'}
          <div class="space-y-3">
            {#if service.key === 'github'}
              <div class="rounded-md bg-muted/50 p-3 text-xs text-muted-foreground">
                <a
                  href="https://github.com/settings/personal-access-tokens/new"
                  target="_blank"
                  rel="noopener noreferrer"
                  class="font-medium text-primary underline underline-offset-4">
                  Create a fine-grained token on GitHub
                </a>
                with access to only one repository. Grant <strong>Contents: read and write</strong>; add pull-request or
                workflow permissions only if the resident needs them.
              </div>
            {/if}
            {#each service.credential_fields as field}
              <label class="block space-y-1">
                <span class="text-sm font-medium">{field.label}</span>
                <input
                  type={field.type || 'text'}
                  value={credentialsFor(service)[field.key] || ''}
                  placeholder={field.placeholder || ''}
                  autocomplete={field.type === 'password' ? 'off' : 'on'}
                  class="w-full rounded-md border bg-background px-3 py-2 text-sm"
                  oninput={(event) => updateCredential(service, field, event.currentTarget.value)} />
                {#if field.help}<span class="block text-xs text-muted-foreground">{field.help}</span>{/if}
              </label>
            {/each}
          </div>
        {:else if service.access_profiles.length > 1}
          <select
            class="w-full rounded-md border bg-background px-3 py-2 text-sm"
            value={profileFor(service)}
            onchange={(event) =>
              (selectedProfiles = { ...selectedProfiles, [service.key]: event.currentTarget.value })}>
            {#each service.access_profiles as profile}
              <option value={profile.key}>{profile.name}{profile.default ? ' — safest default' : ''}</option>
            {/each}
          </select>
        {/if}
        <Button
          type="button"
          onclick={() =>
            service.connection_method === 'credentials' ? connectCredentials(service) : connect(service)}>
          Connect {service.name}
        </Button>
      </div>
    {/each}
  </section>

  <section class="space-y-4">
    <h2 class="text-xl font-semibold">Your connected identities</h2>
    {#if connections.length === 0}
      <p class="rounded-lg border p-5 text-sm text-muted-foreground">
        No personal identities have been attached to this account yet.
      </p>
    {/if}
    {#each connections as connection}
      <div class="space-y-4 rounded-lg border p-5">
        <div class="flex flex-col gap-4 sm:flex-row sm:items-start sm:justify-between">
          <div>
            <h3 class="font-semibold">{connection.label}</h3>
            <p class="text-sm text-muted-foreground">{connection.provider_name} · {connection.identity}</p>
            {#if connection.authority_summary}
              <p class="mt-2 text-xs">{connection.authority_summary}</p>
            {:else if connection.granted_scopes.length > 0}
              <p class="mt-2 text-xs">Granted scopes: {connection.granted_scopes.join(', ')}</p>
            {/if}
          </div>
          <Button type="button" variant="destructive" onclick={() => removeConnection(connection)}>Disconnect</Button>
        </div>
        <label class="flex items-center gap-3 text-sm">
          <input
            type="checkbox"
            checked={connection.enabled_for_new_agents}
            onchange={(event) =>
              updateConnection(connection, { enabled_for_new_agents: event.currentTarget.checked })} />
          Provision to newly created residents by default
        </label>
        <label class="flex items-center gap-3 text-sm">
          <input
            type="checkbox"
            checked={connection.freely_provisionable}
            onchange={(event) => updateConnection(connection, { freely_provisionable: event.currentTarget.checked })} />
          Allow account administrators to provision this identity to residents
        </label>
      </div>
    {/each}
  </section>
</div>
