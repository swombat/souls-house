<script>
  import { router } from '@inertiajs/svelte';
  import AdminAccountDetails from '$lib/components/admin/AdminAccountDetails.svelte';
  import AdminAccountList from '$lib/components/admin/AdminAccountList.svelte';
  import AdminAccountPlaceholder from '$lib/components/admin/AdminAccountPlaceholder.svelte';
  import { createDynamicSync } from '$lib/use-sync';
  import * as logging from '$lib/logging';

  let { accounts = [], selected_account = null } = $props();
  let search = $state('');

  // Create dynamic sync handler
  const updateSync = createDynamicSync();

  // Use dynamic subscriptions since selected_account can change
  $effect(() => {
    const subs = {
      'Account:all': 'accounts', // Always subscribe to all accounts
    };

    // Only subscribe to selected account if one is selected
    if (selected_account) {
      subs[`Account:${selected_account.id}`] = 'selected_account';
    }

    logging.debug('Dynamic subscriptions updated:', subs);
    updateSync(subs);

    logging.debug('Selected account:', selected_account);
  });

  const filtered = $derived(
    accounts.filter((account) => {
      if (!search) return true;
      const term = search.toLowerCase();
      return account.name?.toLowerCase().includes(term) || account.owner?.email_address?.toLowerCase().includes(term);
    })
  );

  function selectAccount(accountId) {
    router.visit(`/admin/accounts?account_id=${accountId}`, {
      preserveState: true,
      preserveScroll: true,
      only: ['selected_account'],
    });
  }

  function showAccounts() {
    router.visit('/admin/accounts', {
      preserveState: true,
      preserveScroll: true,
      only: ['selected_account'],
    });
  }

  function formatDate(dateString) {
    return new Date(dateString).toLocaleDateString('en-US', {
      year: 'numeric',
      month: 'short',
      day: 'numeric',
    });
  }
</script>

<div class="flex h-[calc(100dvh-4rem)] min-h-0 flex-col md:flex-row">
  <AdminAccountList accounts={filtered} selectedAccount={selected_account} bind:search onSelect={selectAccount} />

  <main class="{selected_account ? 'block' : 'hidden'} min-h-0 min-w-0 flex-1 overflow-y-auto bg-background md:block">
    {#if selected_account}
      <div class="sticky top-0 z-10 border-b bg-background p-3 md:hidden">
        <button class="rounded-md px-3 py-2 text-sm font-medium hover:bg-muted" onclick={showAccounts}>
          ← Back to accounts
        </button>
      </div>
      <AdminAccountDetails account={selected_account} {formatDate} />
    {:else}
      <AdminAccountPlaceholder />
    {/if}
  </main>
</div>
