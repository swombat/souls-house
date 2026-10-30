<script>
  import ServiceIcon from '$lib/components/service-icon.svelte';
  import IntegrationConnect from '$lib/components/settings/integration-connect.svelte';
  import IntegrationConnection from '$lib/components/settings/integration-connection.svelte';
  import { serviceDescription, serviceIconClass } from '$lib/service-presentation';
  import { startsOpen } from '$lib/connection-summary';
  import { untrack } from 'svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import { Input } from '$lib/components/shadcn/input/index.js';

  import { XLogo, ArrowLeft, ArrowRight, Plus, Pulse } from 'phosphor-svelte';

  let {
    account,
    services = [],
    connections = [],
    focused_service: focusedService = null,
    can_manage_account: canManageAccount = false,
  } = $props();

  const updateSync = createDynamicSync();
  $effect(() => {
    updateSync({
      [`IntegrationStatus:${account.id}`]: ['connections', 'can_manage_account', 'services'],
    });
  });

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

  // Each integration is a compact row; its switches open underneath. Rows
  // that need something done start open. Several can be open at once.
  // A row's starting state is latched when it first appears, so a WhatsApp
  // row that opened for pairing stays open once the pairing succeeds.
  let openRows = $state({});
  $effect(() => {
    const fresh = connections.filter((connection) => untrack(() => openRows[connection.id]) === undefined);
    for (const connection of fresh) openRows[connection.id] = startsOpen(connection);
  });
  const isOpen = (connection) => openRows[connection.id] ?? startsOpen(connection);
  const toggle = (connection) => (openRows[connection.id] = !isOpen(connection));
  let allOpen = $derived(connections.length > 0 && connections.every(isOpen));
  // Everything that can be connected, in one alphabetical list the filter box
  // narrows by name or description. Polar and X live on their own pages, so
  // they carry an arrow instead of a plus.
  let catalogue = $derived(
    [
      ...services.map((service) => ({
        key: service.key,
        name: service.name,
        description: serviceDescription(service),
        href: `/accounts/${account.id}/integrations?connect=${service.key}`,
        kind: 'service',
      })),
      {
        key: 'link:polar',
        name: 'Polar H10 / RR stream',
        description: 'Publish your own device readings. Always personal; managed on the device streams page.',
        href: `/accounts/${account.id}/device_streams`,
        kind: 'polar',
      },
      {
        key: 'link:x',
        name: 'X posting',
        description:
          "Let this account's residents post to one connected X handle, through the account's own X app (or the house's, for accounts a site admin belongs to). Managed on the X page.",
        href: `/x_integration?account_id=${account.id}`,
        kind: 'x',
      },
    ].sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }))
  );
  let filter = $state('');
  let shownCatalogue = $derived.by(() => {
    const words = filter.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (words.length === 0) return catalogue;
    return catalogue.filter((entry) => {
      const haystack = `${entry.name} ${entry.description ?? ''}`.toLowerCase();
      return words.every((word) => haystack.includes(word));
    });
  });

  function setAll(value) {
    openRows = Object.fromEntries(connections.map((connection) => [connection.id, value]));
  }
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
    <section class="space-y-6" aria-labelledby="existing-heading">
      <div class="flex items-end justify-between gap-4 border-b pb-3">
        <div>
          <h2 id="existing-heading" class="text-xl font-semibold">Your integrations</h2>
          <p class="text-sm text-muted-foreground">
            Everything already connected, and which residents can use it. Tap one to change it.
          </p>
        </div>
        {#if connections.length > 1}
          <button
            type="button"
            class="shrink-0 text-sm text-muted-foreground underline-offset-4 hover:text-foreground hover:underline"
            onclick={() => setAll(!allOpen)}>
            {allOpen ? 'Close all' : 'Open all'}
          </button>
        {/if}
      </div>
      {#if connections.length === 0}
        <div class="rounded-xl border bg-card p-8 text-center">
          <p class="font-medium">Nothing connected yet</p>
          <p class="mt-1 text-sm text-muted-foreground">
            Pick a service below. Once it's connected it appears here, with a switch for each resident.
          </p>
        </div>
      {/if}
      {#each groups as group (group.key)}
        {#if group.connections.length > 0}
          <div class="space-y-2" aria-labelledby={`group-${group.key}`}>
            <div>
              <h3 id={`group-${group.key}`} class="text-sm font-semibold uppercase tracking-wide text-muted-foreground">
                {group.title}
              </h3>
              <p class="text-sm text-muted-foreground">{group.hint}</p>
            </div>
            {#each group.connections as connection (connection.id)}
              <IntegrationConnection
                {connection}
                {account}
                {services}
                open={isOpen(connection)}
                onToggle={() => toggle(connection)} />
            {/each}
          </div>
        {/if}
      {/each}
    </section>

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
      <Input
        type="search"
        aria-label="Filter integrations"
        placeholder="Filter integrations…"
        autocomplete="off"
        bind:value={filter} />
      <ul class="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
        {#each shownCatalogue as entry (entry.key)}
          <li>
            <a
              href={entry.href}
              class="group flex h-full items-start gap-3 rounded-xl border bg-card p-4 transition hover:border-foreground/30 hover:shadow-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring">
              {#if entry.kind === 'polar'}
                <span class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-rose-600 text-white">
                  <Pulse size={22} weight="bold" />
                </span>
              {:else if entry.kind === 'x'}
                <span class="flex size-10 shrink-0 items-center justify-center rounded-lg bg-black text-white">
                  <XLogo size={22} weight="bold" />
                </span>
              {:else}
                <span
                  class={`flex size-10 shrink-0 items-center justify-center rounded-lg ${serviceIconClass(entry.key)}`}>
                  <ServiceIcon provider={entry.key} size={22} />
                </span>
              {/if}
              <span class="min-w-0 flex-1">
                <span class="flex items-center justify-between gap-2 font-medium">
                  {entry.name}
                  {#if entry.kind === 'service'}
                    <Plus size={16} class="shrink-0 text-muted-foreground group-hover:text-foreground" />
                  {:else}
                    <ArrowRight size={16} class="shrink-0 text-muted-foreground group-hover:text-foreground" />
                  {/if}
                </span>
                <span class="mt-0.5 block text-sm text-muted-foreground">{entry.description}</span>
              </span>
            </a>
          </li>
        {/each}
      </ul>
      {#if shownCatalogue.length === 0}
        <p class="text-sm text-muted-foreground">No integration matches “{filter.trim()}”.</p>
      {/if}
    </section>
  {/if}
</AccountSettingsLayout>
