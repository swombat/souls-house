<script>
  import * as Select from '$lib/components/shadcn/select/index.js';
  import { ADMIN_ONLY_TEXT } from '$lib/admin-only.js';

  // A tab with adminOnly is shown only to site admins, and marked red like the
  // house's other site-admin-only controls, selected or not.
  const ADMIN_ONLY_SELECTED =
    'bg-red-100 text-red-700 ring-1 ring-red-300 font-medium dark:bg-red-950/50 dark:text-red-300 dark:ring-red-800';

  let { tabs = [], activeTab = $bindable('appearance') } = $props();
  const active = $derived(tabs.find((tab) => tab.id === activeTab));
</script>

<nav class="md:w-48 md:flex-shrink-0">
  <div class="sm:hidden">
    <Select.Root type="single" value={activeTab} onValueChange={(value) => (activeTab = value)}>
      <Select.Trigger
        class="w-full {active?.adminOnly ? ADMIN_ONLY_TEXT : ''}"
        data-admin-only={active?.adminOnly ? '' : undefined}>
        {active?.label}
      </Select.Trigger>
      <Select.Content>
        {#each tabs as tab (tab.id)}
          <Select.Item value={tab.id} label={tab.label} class={tab.adminOnly ? ADMIN_ONLY_TEXT : ''}
            >{tab.label}</Select.Item>
        {/each}
      </Select.Content>
    </Select.Root>
  </div>

  <div
    class="hidden sm:flex md:flex-col md:sticky md:top-8 gap-1 overflow-x-auto pb-2 md:pb-0 border-b md:border-b-0 border-border">
    {#each tabs as tab (tab.id)}
      <button
        type="button"
        onclick={() => (activeTab = tab.id)}
        class="flex items-center gap-2 px-3 py-2 text-sm rounded-md transition-colors whitespace-nowrap
          {activeTab === tab.id
          ? tab.adminOnly
            ? ADMIN_ONLY_SELECTED
            : 'bg-primary text-primary-foreground font-medium'
          : tab.adminOnly
            ? `${ADMIN_ONLY_TEXT} hover:bg-muted`
            : 'text-muted-foreground hover:text-foreground hover:bg-muted'}"
        title={tab.adminOnly ? `${tab.label} (site admins only)` : undefined}
        data-admin-only={tab.adminOnly ? '' : undefined}>
        <tab.icon size={18} weight={activeTab === tab.id ? 'fill' : 'regular'} />
        {tab.label}
      </button>
    {/each}
  </div>
</nav>
