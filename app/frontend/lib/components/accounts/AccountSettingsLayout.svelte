<script>
  import { Link, router } from '@inertiajs/svelte';
  import * as Select from '$lib/components/shadcn/select/index.js';
  import {
    Buildings,
    Cpu,
    Plugs,
    PlugsConnected,
    Megaphone,
    CurrencyDollar,
    CreditCard,
    BookOpenText,
    DoorOpen,
    UserSound,
    Archive,
    Desktop,
    Users,
    Tag,
    SlidersHorizontal,
    ListChecks,
  } from 'phosphor-svelte';
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
  // The rail is grouped by the question someone arrives with (JQvGmY): the account
  // itself, how its conversations are sorted and behave, what its residents can
  // reach, and how recordings are transcribed.
  let { account, active = 'general', title, description = null, actions, children } = $props();

  const groups = $derived(
    [
      {
        label: 'Account',
        tabs: [
          { id: 'general', label: 'General', icon: Buildings, href: accountPath(account.id) },
          !account.personal && { id: 'users', label: 'Users', icon: Users, href: `/accounts/${account.id}/users` },
          { id: 'house_api', label: `${$siteName} API`, icon: PlugsConnected, href: accountApiKeysPath(account.id) },
          { id: 'billing', label: 'Billing', icon: CreditCard, href: `/accounts/${account.id}/billing` },
          { id: 'costs', label: 'Costs', icon: CurrencyDollar, href: accountCostsPath(account.id) },
          { id: 'portability', label: 'Export and import', icon: Archive, href: `/accounts/${account.id}/portability` },
        ],
      },
      {
        label: 'Conversations',
        tabs: [
          { id: 'rooms', label: 'Rooms', icon: DoorOpen, href: `/accounts/${account.id}/rooms` },
          { id: 'tags', label: 'Tags', icon: Tag, href: `/accounts/${account.id}/tags` },
          { id: 'features', label: 'Features', icon: SlidersHorizontal, href: `/accounts/${account.id}/features` },
        ],
      },
      {
        label: 'Residents',
        tabs: [
          { id: 'model_api_keys', label: 'Model keys', icon: Cpu, href: accountAgentApiKeysPath(account.id) },
          { id: 'integrations', label: 'Integrations', icon: Plugs, href: `/accounts/${account.id}/integrations` },
          { id: 'computers', label: 'Computers', icon: Desktop, href: `/accounts/${account.id}/computers` },
          { id: 'notices', label: 'Notices', icon: Megaphone, href: accountNoticesPath(account.id) },
          { id: 'practices', label: 'Practices', icon: ListChecks, href: `/accounts/${account.id}/practices` },
        ],
      },
      {
        label: 'Transcription',
        tabs: [
          { id: 'voices', label: 'Speakers', icon: UserSound, href: `/accounts/${account.id}/field/voices` },
          { id: 'glossary', label: 'Glossary', icon: BookOpenText, href: `/accounts/${account.id}/glossary` },
        ],
      },
    ].map((group) => ({ ...group, tabs: group.tabs.filter(Boolean) }))
  );

  const tabs = $derived(groups.flatMap((group) => group.tabs));

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
            {#each groups as group (group.label)}
              <Select.Group>
                <Select.GroupHeading>{group.label}</Select.GroupHeading>
                {#each group.tabs as tab (tab.id)}
                  <Select.Item value={tab.id} label={tab.label}>{tab.label}</Select.Item>
                {/each}
              </Select.Group>
            {/each}
          </Select.Content>
        </Select.Root>
      </div>

      <div
        class="hidden sm:flex md:flex-col md:sticky md:top-8 gap-1 md:gap-5 overflow-x-auto pb-2 md:pb-0 border-b md:border-b-0 border-border">
        {#each groups as group (group.label)}
          <div class="flex md:flex-col gap-1" role="group" aria-labelledby={`settings-group-${group.label}`}>
            <p
              id={`settings-group-${group.label}`}
              class="hidden md:block px-3 pb-1 text-xs font-medium uppercase tracking-wide text-muted-foreground/70">
              {group.label}
            </p>
            {#each group.tabs as tab (tab.id)}
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
        {/each}
      </div>
    </nav>

    <div class="flex-1 min-w-0 space-y-6">
      {@render children?.()}
    </div>
  </div>
</div>
