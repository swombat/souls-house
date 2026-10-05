<script>
  import IntegrationConnect from '$lib/components/settings/integration-connect.svelte';
  import IntegrationConnection from '$lib/components/settings/integration-connection.svelte';
  import { serviceDescription, serviceIconClass } from '$lib/service-presentation';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';

  import {
    DropboxLogo,
    GithubLogo,
    ShareNetwork,
    GoogleLogo,
    Heartbeat,
    ArrowLeft,
    ArrowRight,
    Plus,
    Pulse,
  } from 'phosphor-svelte';

  let {
    account,
    services = [],
    connections = [],
    focused_service: focusedService = null,
    can_manage_account: canManageAccount = false,
  } = $props();

  let groups = $derived([
    {
      key: 'account',
      title: 'Account integrations',
      hint: canManageAccount
        ? 'Shared by the account. Any account admin can manage these.'
        : 'Shared by the account and managed by its admins.',
      connections: connections.filter((connection) => connection.management_scope !== 'personal'),
    },
    {
      key: 'personal',
      title: 'Personal integrations',
      hint: 'Connected with your own identity. You choose resident access; account admins can also manage these connections.',
      connections: connections.filter((connection) => connection.management_scope === 'personal'),
    },
  ]);
</script>

<svelte:head><title>Integrations</title></svelte:head>

<AccountSettingsLayout
  {account}
  active="integrations"
  title={focusedService ? `Connect ${focusedService.name}` : 'Integrations'}
  description={focusedService
    ? serviceDescription(focusedService)
    : `Connect a service once, then choose which residents in ${account.name} may use it.`}>
  {#if focusedService}
    <a
      href={`/accounts/${account.id}/integrations`}
      class="inline-flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground">
      <ArrowLeft size={16} /> Integrations
    </a>
    <div class="max-w-2xl space-y-6">
      {#key focusedService.key}
        <IntegrationConnect {account} {focusedService} {canManageAccount} />
      {/key}
    </div>
  {:else}
    <section
      id="connect-new"
      aria-labelledby="connect-new-heading"
      class="space-y-4 rounded-2xl border border-dashed bg-muted/30 p-5 sm:p-6">
      <div>
        <h2 id="connect-new-heading" class="text-xl font-semibold">Connect a new integration</h2>
        <p class="text-sm text-muted-foreground">
          Pick a service to connect. You can connect more than one of the same kind, such as several GitHub repositories
          or Google accounts.
        </p>
      </div>
      <ul class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {#each services as service}
          <li>
            <a
              href={`/accounts/${account.id}/integrations?connect=${service.key}`}
              class="group flex h-full items-start gap-3 rounded-xl border bg-card p-4 transition hover:border-foreground/30 hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
              <span
                class={`flex size-10 shrink-0 items-center justify-center rounded-lg ${serviceIconClass(service.key)}`}>
                {#if service.key === 'dropbox'}
                  <DropboxLogo size={22} weight="fill" />
                {:else if service.key === 'google_workspace'}
                  <GoogleLogo size={22} weight="bold" />
                {:else if service.key === 'github'}
                  <GithubLogo size={22} weight="fill" />
                {:else if service.key === 'tailscale'}
                  <ShareNetwork size={22} weight="bold" />
                {:else}
                  <Heartbeat size={22} weight="fill" />
                {/if}
              </span>
              <span class="min-w-0 flex-1">
                <span class="flex items-center justify-between gap-2 font-medium">
                  {service.name}
                  <Plus size={16} class="shrink-0 text-muted-foreground group-hover:text-foreground" />
                </span>
                <span class="mt-0.5 block text-sm text-muted-foreground">{serviceDescription(service)}</span>
              </span>
            </a>
          </li>
        {/each}
        <li>
          <a
            href={`/accounts/${account.id}/device_streams`}
            class="group flex h-full items-start gap-3 rounded-xl border bg-card p-4 transition hover:border-foreground/30 hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
            <span class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-rose-600 text-white">
              <Pulse size={22} weight="bold" />
            </span>
            <span class="min-w-0 flex-1">
              <span class="flex items-center justify-between gap-2 font-medium">
                Polar H10 / RR stream
                <ArrowRight size={16} class="shrink-0 text-muted-foreground group-hover:text-foreground" />
              </span>
              <span class="mt-0.5 block text-sm text-muted-foreground">
                Publish your own device readings. Always personal; managed on the device streams page.
              </span>
            </span>
          </a>
        </li>
      </ul>
    </section>

    <section class="space-y-6" aria-labelledby="existing-heading">
      <div class="border-b pb-3">
        <h2 id="existing-heading" class="text-xl font-semibold">Your integrations</h2>
        <p class="text-sm text-muted-foreground">Everything already connected, and which residents can use it.</p>
      </div>
      {#if connections.length === 0}
        <div class="rounded-xl border bg-card p-8 text-center">
          <p class="font-medium">Nothing connected yet</p>
          <p class="mt-1 text-sm text-muted-foreground">
            Pick a service above. Once it's connected it appears here, with a switch for each resident.
          </p>
        </div>
      {/if}
      {#each groups as group (group.key)}
        {#if group.connections.length > 0}
          <div class="space-y-3" aria-labelledby={`group-${group.key}`}>
            <div>
              <h3 id={`group-${group.key}`} class="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
                {group.title}
              </h3>
              <p class="text-sm text-muted-foreground">{group.hint}</p>
            </div>
            {#each group.connections as connection (connection.id)}
              <IntegrationConnection {connection} {account} {services} />
            {/each}
          </div>
        {/if}
      {/each}
    </section>
  {/if}
</AccountSettingsLayout>
