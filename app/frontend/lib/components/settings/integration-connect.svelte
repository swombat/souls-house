<script>
  import ServiceIcon from '$lib/components/service-icon.svelte';
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { serviceIconClass } from '$lib/service-presentation';
  import { submitNativePost } from '$lib/integration-forms';
  import TailscaleKeyNote from './tailscale-key-note.svelte';
  import ServiceAuthoritySelector from '$lib/components/service-authority-selector.svelte';
  let { account, focusedService, canManageAccount = false } = $props();
  let managementScope = $state('personal');
  let availableScopes = $derived(
    (focusedService.management_scopes || ['personal']).filter((scope) => scope === 'personal' || canManageAccount)
  );
  let effectiveScope = $derived(availableScopes.includes(managementScope) ? managementScope : availableScopes[0]);
  const scopeOptions = [
    {
      value: 'personal',
      title: 'Just me',
      detail: 'Uses your identity. You choose resident access; account admins can manage or disconnect it.',
    },
    {
      value: 'account_managed',
      title: 'The whole account',
      detail: 'Managed by account admins. Choose resident access after connecting.',
    },
  ];
  let selectedProfiles = $state({});
  let authoritySelections = $state({});
  let credentialValues = $state({});
  function profileFor(service) {
    return selectedProfiles[service.key] || service.access_profiles.find((profile) => profile.default)?.key;
  }

  function connect(service) {
    const data = {
      provider: service.key,
      management_scope: effectiveScope,
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
      management_scope: effectiveScope,
      credentials: credentialsFor(service),
    });
  }
</script>

<div class="space-y-5 rounded-xl border bg-card p-6 shadow-sm">
  <div class="flex items-center gap-4">
    <div class={`flex size-12 items-center justify-center rounded-xl ${serviceIconClass(focusedService.key)}`}>
      <ServiceIcon provider={focusedService.key} size={26} />
    </div>
    <h2 class="text-xl font-semibold">{focusedService.name}</h2>
  </div>

  {#if canManageAccount && availableScopes.length > 1}
    <div role="radiogroup" aria-label="Integration scope" class="space-y-2">
      <p class="text-sm font-medium">Who should own this connection?</p>
      <div class="grid gap-2 sm:grid-cols-2">
        {#each scopeOptions as option (option.value)}
          <label
            class={`flex cursor-pointer gap-3 rounded-lg border p-3 text-sm transition ${
              managementScope === option.value ? 'border-primary bg-primary/5 ring-1 ring-primary' : 'hover:bg-muted/50'
            }`}>
            <input
              type="radio"
              name="management_scope"
              value={option.value}
              bind:group={managementScope}
              class="mt-0.5" />
            <span>
              <span class="block font-medium">{option.title}</span>
              <span class="block text-muted-foreground">{option.detail}</span>
            </span>
          </label>
        {/each}
      </div>
    </div>
  {:else}
    <p class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
      {#if focusedService.management_scopes?.length === 1 && focusedService.management_scopes[0] === 'account_managed'}
        {focusedService.name} is connected for the whole account. It belongs to the account, not to you: account admins manage
        or disconnect it and choose which residents can use it.
      {:else if canManageAccount}
        {focusedService.name} can only be connected personally. It will belong to you, and you choose which residents can
        use it.
      {:else}
        This will be your personal integration. You choose which residents can use it. Account admins can also manage or
        disconnect the connection.
      {/if}
    </p>
  {/if}

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
      {#if focusedService.key === 'pipedrive'}
        <div class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
          Residents with this connection act as you in Pipedrive, with all of your Pipedrive permissions. Find the token
          under your profile menu → Personal preferences → API. Pipedrive allows one token per user, so anything else
          using it keeps working until you regenerate it.
        </div>
      {/if}
      {#if focusedService.key === 'honeybadger'}
        <div class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
          Residents with this connection see your errors, including the request details Honeybadger stored with them,
          and act as you in Honeybadger. The token carries all of your permissions, so a resident could resolve or
          delete errors too; they are told to read unless asked. Find it under User settings → Authentication. It is not
          a project's API key.
        </div>
      {/if}
      {#if focusedService.key === 'porkbun'}
        <div class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
          Residents with this connection can change DNS records, URL forwards and nameservers on your Porkbun domains,
          which can take a site or its email offline if done wrong. Create the key under Account → API Access and give
          it the <span class="font-medium">dns</span> scope (add <span class="font-medium">domains</span> for nameservers).
          A full-access key can also buy and renew domains and add credit; residents are told not to, but only the scopes
          actually stop it. If a domain refuses, switch on API Access for it in Porkbun.
        </div>
      {/if}
      {#if focusedService.key === 'cloudflare'}
        <div class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
          Residents with this connection can do whatever the token allows on your Cloudflare zones. Create it under My
          Profile → API Tokens → Create Token, starting from the "Edit zone DNS" template, limited to the zones
          residents should manage; add the Single Redirect permission if they should manage redirects. Don't use the
          Global API Key.
        </div>
      {/if}
      {#if focusedService.key === 'ghost'}
        <div class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
          Residents with this connection can write on your Ghost site. An Admin API key can do anything to its content:
          create, edit, publish and delete posts and pages, and send posts to your members as newsletters. Residents are
          told to write drafts, publish only when you ask, and never send a newsletter unless you ask for that email. In
          Ghost Admin open Settings → Integrations → Add custom integration, then copy its API URL and Admin API key.
          Posts appear under the site owner's name; a staff access token (your profile → Staff access token) makes them
          appear under that staff user instead.
        </div>
      {/if}
      {#if focusedService.key === 'twitterapi_io'}
        <div class="rounded-md bg-muted/50 p-3 text-sm text-muted-foreground">
          This key pays for the account's tweet streams in the Field: each check costs a little of your TwitterAPI.io
          credit, about $0.15 per 1,000 posts brought back and at least $0.00015 a call. Create an account on
          twitterapi.io, add credit, and copy the key from its dashboard. It reads public posts only and cannot post.
        </div>
      {/if}
      {#if focusedService.key === 'tailscale'}
        <TailscaleKeyNote />
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

  <div class="flex flex-col gap-3 border-t pt-4 sm:flex-row sm:justify-end">
    <Button variant="outline" href={`/accounts/${account.id}/integrations`}>Cancel</Button>
    <Button
      type="button"
      disabled={focusedService.authority_groups.length > 0 && !hasAuthority(focusedService)}
      onclick={() =>
        ['credentials', 'pairing'].includes(focusedService.connection_method)
          ? connectCredentials(focusedService)
          : connect(focusedService)}>
      Connect {focusedService.name}
    </Button>
  </div>
</div>
