<script>
  import { Link, router } from '@inertiajs/svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { Buildings, Cpu, Plugs, PlugsConnected, Megaphone, CurrencyDollar } from 'phosphor-svelte';
  import { siteName } from '$lib/branding';
  import {
    accountPath,
    accountAgentApiKeysPath,
    accountApiKeysPath,
    accountNoticesPath,
    accountCostsPath,
  } from '@/routes';

  // Account settings share one left-hand tab rail, matching resident settings.
  // Each tab keeps its own URL and controller, so permissions stay where they were.
  let { account, active = 'general', title, description = null, actions, children } = $props();

  const tabs = $derived([
    { id: 'general', label: 'General', icon: Buildings, href: accountPath(account.id) },
    { id: 'model_api_keys', label: 'Model API keys', icon: Cpu, href: accountAgentApiKeysPath(account.id) },
    { id: 'house_api', label: `${$siteName} API`, icon: PlugsConnected, href: accountApiKeysPath(account.id) },
    { id: 'integrations', label: 'Integrations', icon: Plugs, href: `/accounts/${account.id}/integrations` },
    { id: 'notices', label: 'Notices', icon: Megaphone, href: accountNoticesPath(account.id) },
    { id: 'costs', label: 'Costs', icon: CurrencyDollar, href: accountCostsPath(account.id) },
  ]);

  const activeLabel = $derived(tabs.find((tab) => tab.id === active)?.label);
</script>

<div class="p-8 max-w-6xl mx-auto">
  <div class="mb-8 flex items-start justify-between gap-4">
    <div class="min-w-0">
      <p class="text-sm text-muted-foreground truncate">{account.name} · Account settings</p>
      <h1 class="text-3xl font-bold">{title}</h1>
      {#if description}
        <p class="mt-1 text-muted-foreground">{description}</p>
      {/if}
    </div>
    {#if actions}
      <div class="shrink-0">{@render actions()}</div>
    {/if}
  </div>

  <div class="flex flex-col md:flex-row gap-6 md:gap-8">
    <nav class="md:w-52 md:flex-shrink-0" aria-label="Account settings">
      <div class="sm:hidden">
        <Select.Root
          type="single"
          value={active}
          onValueChange={(value) => router.visit(tabs.find((tab) => tab.id === value).href)}>
          <Select.Trigger class="w-full">{activeLabel}</Select.Trigger>
          <Select.Content>
            {#each tabs as tab (tab.id)}
              <Select.Item value={tab.id} label={tab.label}>{tab.label}</Select.Item>
            {/each}
          </Select.Content>
        </Select.Root>
      </div>

      <div
        class="hidden sm:flex md:flex-col md:sticky md:top-8 gap-1 overflow-x-auto pb-2 md:pb-0 border-b md:border-b-0 border-border">
        {#each tabs as tab (tab.id)}
          <Link
            href={tab.href}
            aria-current={active === tab.id ? 'page' : undefined}
            class="flex items-center gap-2 px-3 py-2 text-sm rounded-md transition-colors whitespace-nowrap
              {active === tab.id
              ? 'bg-primary text-primary-foreground font-medium'
              : 'text-muted-foreground hover:text-foreground hover:bg-muted'}">
            <tab.icon size={18} weight={active === tab.id ? 'fill' : 'regular'} />
            {tab.label}
          </Link>
        {/each}
      </div>
    </nav>

    <div class="flex-1 min-w-0 space-y-6">
      {@render children?.()}
    </div>
  </div>
</div>
