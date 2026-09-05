<script>
  let { accounts = [], selectedAccount = null, search = $bindable(''), onSelect } = $props();
</script>

<aside class="max-h-56 w-full shrink-0 border-r border-border bg-card flex flex-col md:max-h-none md:w-64 xl:w-80">
  <header class="p-4 border-b border-border bg-muted/30">
    <h2 class="text-lg font-semibold mb-3">Accounts</h2>
    <input
      type="search"
      placeholder="Search accounts..."
      bind:value={search}
      class="flex h-9 w-full rounded-md border border-input bg-background px-3 py-1 text-sm shadow-sm transition-colors placeholder:text-muted-foreground focus-visible:outline-none focus-visible:ring-1 focus-visible:ring-ring" />
  </header>

  <div class="flex-1 overflow-y-auto">
    {#if accounts.length === 0}
      <div class="p-4 text-center text-muted-foreground">
        {search ? 'No accounts match your search' : 'No accounts found'}
      </div>
    {:else}
      <nav>
        {#each accounts as account (account.id)}
          <button
            onclick={() => onSelect(account.id)}
            class="w-full text-left p-4 hover:bg-muted/50 transition-colors border-b border-border
                   {selectedAccount?.id === account.id ? 'bg-primary/10 border-l-4 border-l-primary' : ''}
                   {account.disabled ? 'bg-neutral-50 dark:bg-neutral-800 opacity-50' : ''}">
            <div class="font-medium text-base">{account.name}</div>
            <div class="text-sm text-muted-foreground mt-1">
              {account.account_type === 'personal' ? 'Personal' : 'Organization'}
              {#if account.disabled}
                • Disabled
              {/if}
              {#if account.users_count}
                •
                {account.users_count}
                {account.users_count === 1 ? 'user' : 'users'}
              {/if}
            </div>
            {#if account.owner}
              <div class="text-xs text-muted-foreground/80 mt-1">Owner: {account.owner.email_address}</div>
            {/if}
          </button>
        {/each}
      </nav>
    {/if}
  </div>
</aside>
