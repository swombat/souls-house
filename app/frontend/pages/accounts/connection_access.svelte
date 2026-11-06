<script>
  import { page } from '@inertiajs/svelte';
  import FlashMessages from '$lib/components/FlashMessages.svelte';
  import AccountSettingsLayout from '$lib/components/accounts/AccountSettingsLayout.svelte';
  import ConnectionResidentAccess from '$lib/components/settings/connection-resident-access.svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { connectionTitle, residentHasAccess } from '$lib/connection-summary';
  import { WarningCircle } from 'phosphor-svelte';

  // The step a new integration lands on (YgDZGe): connected, but no resident
  // can use it until someone is switched on here. The same switches as the
  // Integrations card, on their own, then back to the list.
  let { account, connection, integrations_url } = $props();

  let title = $derived(connectionTitle(connection));
  let granted = $derived((connection.residents || []).filter(residentHasAccess));
</script>

<svelte:head><title>Choose residents</title></svelte:head>

<AccountSettingsLayout
  {account}
  active="integrations"
  title={`Who can use ${connection.provider_name}?`}
  description={`${title} is connected. No resident can use it until you switch them on below.`}>
  <FlashMessages flash={$page.props.flash} />

  <div class="max-w-2xl space-y-4" data-testid="connection-access-page">
    {#if granted.length === 0}
      <p
        class="flex items-center gap-2 rounded-lg border border-red-300 bg-red-50 px-4 py-3 text-sm font-medium text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300"
        data-testid="connection-access-none">
        <WarningCircle size={18} weight="bold" class="shrink-0" />
        No residents have access yet.
      </p>
    {/if}

    <section class="rounded-xl border bg-card p-4 shadow-sm sm:p-5">
      <ConnectionResidentAccess {connection} />
    </section>

    <div class="flex items-center gap-3">
      <Button href={integrations_url} size="sm" data-testid="connection-access-done">
        {granted.length === 0 ? 'Skip for now' : 'Done'}
      </Button>
      <p class="text-sm text-muted-foreground">You can change this later on the Integrations page.</p>
    </div>
  </div>
</AccountSettingsLayout>
