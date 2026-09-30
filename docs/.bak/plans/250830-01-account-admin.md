# Accounts Management - Simple Implementation Plan

## Summary

Add a simple admin page to view all accounts and their users. One controller action, one Svelte component, minimal code.

## Implementation

### 1. Controller

Create `app/controllers/admin/accounts_controller.rb`:

```ruby
class Admin::AccountsController < ApplicationController
  before_action :require_site_admin
  
  def index
    @accounts = Account.includes(:owner, :account_users => :user)
                      .order(created_at: :desc)
    
    render inertia: 'admin/accounts', props: {
      accounts: @accounts.map { |account|
        {
          id: account.id,
          name: account.name,
          slug: account.slug,
          account_type: account.account_type,
          is_site_admin: account.is_site_admin,
          created_at: account.created_at.to_s,
          owner: {
            email: account.owner&.email_address,
            name: account.owner&.full_name
          },
          users: account.account_users.map { |au|
            {
              email: au.user.email_address,
              name: au.user.full_name,
              role: au.role,
              confirmed: au.confirmed?
            }
          }
        }
      }
    }
  end
  
  private
  
  def require_site_admin
    redirect_to root_path unless Current.user&.site_admin
  end
end
```

### 2. Route

Add to `config/routes.rb`:

```ruby
namespace :admin do
  resources :accounts, only: [:index]
end
```

### 3. Page Component

Create `app/frontend/pages/admin/accounts.svelte`:

```svelte
<script>
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';
  
  let { accounts = [] } = $props();
  let searchTerm = $state('');
  let selectedAccount = $state(null);
  
  const filteredAccounts = $derived(
    accounts.filter(account => {
      if (!searchTerm) return true;
      const term = searchTerm.toLowerCase();
      return account.name.toLowerCase().includes(term) ||
             account.owner?.email?.toLowerCase().includes(term) ||
             account.slug.toLowerCase().includes(term);
    })
  );
</script>

<div class="container mx-auto py-8">
  <h1 class="text-3xl font-bold mb-6">Accounts Management</h1>
  
  <div class="mb-6">
    <Input
      type="text"
      placeholder="Search accounts..."
      bind:value={searchTerm}
      class="max-w-md"
    />
  </div>
  
  <div class="grid grid-cols-1 lg:grid-cols-3 gap-6">
    <!-- Account List -->
    <div class="lg:col-span-1 space-y-3">
      {#each filteredAccounts as account}
        <button
          onclick={() => selectedAccount = account}
          class="w-full text-left p-4 border rounded-lg hover:bg-muted transition
                 {selectedAccount?.id === account.id ? 'bg-muted border-primary' : ''}"
        >
          <div class="font-medium">{account.name}</div>
          <div class="text-sm text-muted-foreground">{account.owner?.email || 'No owner'}</div>
          <div class="flex gap-2 mt-2">
            <Badge variant={account.account_type === 'personal' ? 'secondary' : 'default'}>
              {account.account_type}
            </Badge>
            {#if account.is_site_admin}
              <Badge variant="destructive">Site Admin</Badge>
            {/if}
          </div>
        </button>
      {/each}
      
      {#if filteredAccounts.length === 0}
        <p class="text-muted-foreground text-center py-8">No accounts found</p>
      {/if}
    </div>
    
    <!-- Account Details -->
    <div class="lg:col-span-2">
      {#if selectedAccount}
        <Card.Root>
          <Card.Header>
            <Card.Title>{selectedAccount.name}</Card.Title>
            <Card.Description>
              {selectedAccount.account_type} account · {selectedAccount.slug}
            </Card.Description>
          </Card.Header>
          <Card.Content>
            <div class="space-y-4">
              <div>
                <h3 class="font-semibold mb-2">Account Info</h3>
                <dl class="space-y-1 text-sm">
                  <div>
                    <dt class="inline text-muted-foreground">Created:</dt>
                    <dd class="inline ml-2">{selectedAccount.created_at}</dd>
                  </div>
                  <div>
                    <dt class="inline text-muted-foreground">Owner:</dt>
                    <dd class="inline ml-2">
                      {selectedAccount.owner?.name || selectedAccount.owner?.email || 'None'}
                    </dd>
                  </div>
                </dl>
              </div>
              
              <div>
                <h3 class="font-semibold mb-2">Users ({selectedAccount.users.length})</h3>
                <div class="space-y-2">
                  {#each selectedAccount.users as user}
                    <div class="flex justify-between items-center py-2 border-b">
                      <div>
                        <div class="font-medium">{user.name || user.email}</div>
                        <div class="text-sm text-muted-foreground">{user.email}</div>
                      </div>
                      <div class="flex gap-2">
                        <Badge variant="outline">{user.role}</Badge>
                        {#if user.confirmed}
                          <Badge variant="secondary">Confirmed</Badge>
                        {/if}
                      </div>
                    </div>
                  {/each}
                </div>
              </div>
            </div>
          </Card.Content>
        </Card.Root>
      {:else}
        <div class="h-full flex items-center justify-center text-muted-foreground">
          Select an account to view details
        </div>
      {/if}
    </div>
  </div>
</div>
```

### 4. Navigation Link

Add to the admin dropdown in navbar (if site admin):

```svelte
<!-- In existing admin dropdown -->
<DropdownMenu.Item onclick={() => router.visit('/admin/accounts')}>
  <Users class="mr-2 size-4" />
  <span>Manage Accounts</span>
</DropdownMenu.Item>
```

## That's It

- No deferred loading - load all data at once (simpler)
- No virtual scrolling - browser handles it fine
- No caching - not needed for admin features
- No service objects - just a simple controller
- No complex state management - just local component state
- No phases or metrics - ship it and iterate if needed

Total implementation time: ~1 hour

## If Performance Becomes an Issue Later

Only if you have thousands of accounts and it becomes slow:

1. Add pagination with Pagy gem
2. Load account details via a separate AJAX call
3. Add database indexes if queries are slow

But don't do any of this until you actually need it.