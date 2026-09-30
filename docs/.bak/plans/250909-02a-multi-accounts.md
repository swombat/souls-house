# Multi-Account Support Implementation Plan

## Executive Summary

This plan implements full multi-account support in the Rails 8 + Svelte 5 + Inertia.js application. Users can have one personal account and multiple team accounts, with seamless switching between accounts via a refined UI. The implementation follows Rails Way principles with fat models, RESTful routes, and authorization through associations.

## Architecture Overview

### Key Design Decisions

1. **URL-based Account Context**: Current account determined from `/accounts/:account_id/...` URLs, not session state
2. **Authorization via Associations**: Using Rails associations for scoping (`current_user.accounts`)
3. **Rails-only Validations**: All business rules enforced in models, no database constraints
4. **RESTful Controllers**: Minimal custom actions, leveraging standard REST verbs
5. **Real-time Updates**: Using existing Broadcastable/SyncAuthorizable patterns for live updates

### Data Model Changes

The existing models (`User`, `Account`, `Membership`) already support the core requirements. We need minimal model adjustments:

1. Add methods for account switching and management
2. Enhance validation for personal account limits
3. Add scopes for better account querying

### Frontend Architecture

1. **Account Switcher**: Dropdown in navbar showing all available accounts
2. **Account Management Page**: List all accounts, create personal/team accounts
3. **Smart Redirects**: Context-aware navigation when switching accounts

## Step-by-Step Implementation

### Phase 1: Backend Model Enhancements

- [ ] **Update User Model** (`app/models/user.rb`)
  ```ruby
  # Add methods for multi-account support
  def has_personal_account?
    personal_account.present?
  end
  
  def can_create_personal_account?
    !has_personal_account?
  end
  
  def team_accounts
    accounts.team.includes(:memberships)
  end
  
  def all_accounts_for_switcher
    accounts.confirmed.includes(:owner).order(account_type: :asc, name: :asc)
  end
  
  # Update the find_or_create_membership! method to not auto-create personal account
  def find_or_create_membership!(account = nil)
    return personal_membership if personal_membership&.persisted? && account.nil?
    
    if account.nil? && !has_personal_account?
      # Create personal account only if explicitly needed
      account = Account.create!(
        name: "#{email_address}'s Account",
        account_type: :personal
      )
      
      memberships.create!(
        account: account,
        role: "owner",
        skip_confirmation: confirmed? # Skip if user already confirmed elsewhere
      )
    elsif account
      # Join existing account
      memberships.find_or_create_by!(account: account)
    else
      raise "No account context available"
    end
  end
  ```

- [ ] **Update Account Model** (`app/models/account.rb`)
  ```ruby
  # Add display helpers
  def display_name
    if personal?
      owner&.full_name.present? ? "Personal" : "Personal Account"
    else
      name
    end
  end
  
  def display_name_with_type
    if personal?
      "#{display_name} (Personal)"
    else
      "#{name} (Team)"
    end
  end
  
  # Scope for switcher
  scope :for_switcher, -> { includes(:owner).order(account_type: :asc, name: :asc) }
  ```

- [ ] **Update Membership Model** (`app/models/membership.rb`)
  ```ruby
  # Add scope for confirmed memberships
  scope :active, -> { confirmed }
  
  # Update validation to allow team invites without personal accounts
  def enforce_personal_account_rules
    if account&.personal?
      errors.add(:role, "must be owner for personal accounts") if role != "owner"
      errors.add(:base, "Personal accounts can only have one user") if account.memberships.where.not(id: id).exists?
      errors.add(:base, "Cannot invite to personal accounts") if invitation?
    end
  end
  ```

### Phase 2: Controller Updates

- [ ] **Create AccountsController Index Action** (`app/controllers/accounts_controller.rb`)
  ```ruby
  def index
    @accounts = Current.user.all_accounts_for_switcher
    render inertia: "accounts/index", props: {
      accounts: @accounts.map(&:as_json),
      can_create_personal: Current.user.can_create_personal_account?,
      current_account_id: current_account&.id
    }
  end
  
  def new
    @account_type = params[:type] || "team"
    
    if @account_type == "personal" && !Current.user.can_create_personal_account?
      return redirect_to accounts_path, alert: "You already have a personal account"
    end
    
    render inertia: "accounts/new", props: {
      account_type: @account_type
    }
  end
  
  def create
    @account = build_new_account
    
    if @account.save
      membership = Current.user.memberships.create!(
        account: @account,
        role: "owner",
        skip_confirmation: true
      )
      
      audit(:create_account, @account, account_type: @account.account_type)
      redirect_to account_path(@account), notice: "Account created successfully"
    else
      redirect_to new_account_path(type: account_params[:account_type]), 
        inertia: { errors: @account.errors }
    end
  end
  
  private
  
  def build_new_account
    account_type = account_params[:account_type] || "team"
    
    if account_type == "personal"
      Account.new(
        name: "#{Current.user.email_address}'s Account",
        account_type: :personal
      )
    else
      Account.new(account_params)
    end
  end
  
  def account_params
    params.require(:account).permit(:name, :account_type)
  end
  ```

- [ ] **Update ApplicationController** (`app/controllers/application_controller.rb`)
  ```ruby
  # Add helper for account switching redirects
  def redirect_after_account_switch(new_account)
    # If on an account-specific page, go to new account's home
    if params[:account_id].present?
      redirect_to account_path(new_account)
    else
      # Stay on current page with new account context
      redirect_to request.path
    end
  end
  ```

- [ ] **Update Routes** (`config/routes.rb`)
  ```ruby
  resources :accounts do
    member do
      post :switch  # For explicit account switching if needed
    end
    # ... existing nested routes
  end
  ```

### Phase 3: Frontend Components

- [ ] **Update Navbar Account Switcher** (`app/frontend/lib/components/navigation/Navbar.svelte`)
  ```svelte
  <script>
    import { page, router } from '@inertiajs/svelte';
    import { accountsPath, accountPath, newAccountPath } from '@/routes';
    
    const currentUser = $derived($page.props?.user);
    const currentAccount = $derived($page.props?.account);
    const userAccounts = $derived(currentUser?.accounts || []);
    const hasMultipleAccounts = $derived(userAccounts.length > 1);
    
    function switchAccount(accountId) {
      // Navigate to the selected account's page
      router.visit(accountPath(accountId));
    }
  </script>
  
  <!-- In the account dropdown section -->
  <DropdownMenu.Group>
    <DropdownMenu.GroupHeading>
      <div class="text-xs font-normal text-muted-foreground">Current Account</div>
      <div class="text-sm font-semibold truncate">
        {currentAccount?.display_name || 'No Account'}
      </div>
    </DropdownMenu.GroupHeading>
    
    {#if hasMultipleAccounts}
      <DropdownMenu.Separator />
      <DropdownMenu.Sub>
        <DropdownMenu.SubTrigger>
          <ArrowsClockwise class="mr-2 size-4" />
          <span>Switch Account</span>
        </DropdownMenu.SubTrigger>
        <DropdownMenu.SubContent>
          {#each userAccounts as account}
            <DropdownMenu.Item 
              onclick={() => switchAccount(account.id)}
              class={account.id === currentAccount?.id ? 'bg-accent' : ''}>
              {#if account.personal}
                <User class="mr-2 size-4" />
              {:else}
                <Buildings class="mr-2 size-4" />
              {/if}
              {account.display_name}
            </DropdownMenu.Item>
          {/each}
          <DropdownMenu.Separator />
          <DropdownMenu.Item onclick={() => router.visit(accountsPath())}>
            <Gear class="mr-2 size-4" />
            Manage Accounts
          </DropdownMenu.Item>
        </DropdownMenu.SubContent>
      </DropdownMenu.Sub>
    {/if}
  </DropdownMenu.Group>
  ```

- [ ] **Create Accounts Index Page** (`app/frontend/pages/accounts/index.svelte`)
  ```svelte
  <script>
    import { page, router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button';
    import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
    import { User, Buildings, Plus } from 'phosphor-svelte';
    import { accountPath, newAccountPath } from '@/routes';
    import { useSync } from '$lib/use-sync';
    
    let { accounts = [], can_create_personal = false, current_account_id } = $props();
    
    // Real-time sync when accounts change
    useSync({
      'Account:all': 'accounts'
    });
    
    const personalAccount = $derived(accounts.find(a => a.personal));
    const teamAccounts = $derived(accounts.filter(a => !a.personal));
  </script>
  
  <div class="container mx-auto py-8 max-w-4xl">
    <div class="mb-8">
      <h1 class="text-3xl font-bold mb-2">My Accounts</h1>
      <p class="text-muted-foreground">Manage your personal and team accounts</p>
    </div>
    
    <!-- Personal Account Section -->
    <div class="mb-8">
      <h2 class="text-xl font-semibold mb-4 flex items-center gap-2">
        <User class="size-5" />
        Personal Account
      </h2>
      
      {#if personalAccount}
        <Card class="cursor-pointer hover:bg-accent/50 transition-colors"
              onclick={() => router.visit(accountPath(personalAccount.id))}>
          <CardHeader>
            <CardTitle class="flex items-center justify-between">
              {personalAccount.name}
              {#if personalAccount.id === current_account_id}
                <Badge variant="secondary">Current</Badge>
              {/if}
            </CardTitle>
            <CardDescription>
              Your personal workspace
            </CardDescription>
          </CardHeader>
        </Card>
      {:else if can_create_personal}
        <Card class="border-dashed">
          <CardContent class="flex items-center justify-center py-8">
            <Button onclick={() => router.visit(newAccountPath({ type: 'personal' }))}>
              <Plus class="mr-2 size-4" />
              Create Personal Account
            </Button>
          </CardContent>
        </Card>
      {:else}
        <p class="text-muted-foreground">No personal account available</p>
      {/if}
    </div>
    
    <!-- Team Accounts Section -->
    <div>
      <div class="flex items-center justify-between mb-4">
        <h2 class="text-xl font-semibold flex items-center gap-2">
          <Buildings class="size-5" />
          Team Accounts
        </h2>
        <Button onclick={() => router.visit(newAccountPath({ type: 'team' }))}
                size="sm">
          <Plus class="mr-2 size-4" />
          New Team
        </Button>
      </div>
      
      {#if teamAccounts.length > 0}
        <div class="space-y-3">
          {#each teamAccounts as account}
            <Card class="cursor-pointer hover:bg-accent/50 transition-colors"
                  onclick={() => router.visit(accountPath(account.id))}>
              <CardHeader>
                <CardTitle class="flex items-center justify-between">
                  {account.name}
                  <div class="flex items-center gap-2">
                    {#if account.members_count > 1}
                      <Badge variant="outline">
                        {account.members_count} members
                      </Badge>
                    {/if}
                    {#if account.id === current_account_id}
                      <Badge variant="secondary">Current</Badge>
                    {/if}
                  </div>
                </CardTitle>
                <CardDescription>
                  {account.owned_by_current_user ? 'Owner' : 'Member'}
                </CardDescription>
              </CardHeader>
            </Card>
          {/each}
        </div>
      {:else}
        <Card class="border-dashed">
          <CardContent class="flex flex-col items-center justify-center py-8 text-center">
            <Buildings class="size-8 text-muted-foreground mb-3" />
            <p class="text-muted-foreground mb-4">No team accounts yet</p>
            <Button onclick={() => router.visit(newAccountPath({ type: 'team' }))}>
              <Plus class="mr-2 size-4" />
              Create Your First Team
            </Button>
          </CardContent>
        </Card>
      {/if}
    </div>
  </div>
  ```

- [ ] **Create New Account Page** (`app/frontend/pages/accounts/new.svelte`)
  ```svelte
  <script>
    import { page, router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button';
    import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '$lib/components/shadcn/card';
    import { Input } from '$lib/components/shadcn/input';
    import { Label } from '$lib/components/shadcn/label';
    import { accountsPath } from '@/routes';
    
    let { account_type = 'team', errors = {} } = $props();
    let accountName = $state('');
    let isSubmitting = $state(false);
    
    function handleSubmit(e) {
      e.preventDefault();
      isSubmitting = true;
      
      const data = {
        account: {
          account_type,
          name: account_type === 'team' ? accountName : undefined
        }
      };
      
      router.post(accountsPath(), data, {
        onFinish: () => { isSubmitting = false; }
      });
    }
  </script>
  
  <div class="container mx-auto py-8 max-w-lg">
    <Card>
      <CardHeader>
        <CardTitle>
          Create {account_type === 'personal' ? 'Personal' : 'Team'} Account
        </CardTitle>
        <CardDescription>
          {#if account_type === 'personal'}
            Your personal workspace for individual projects
          {:else}
            Collaborate with others in a shared workspace
          {/if}
        </CardDescription>
      </CardHeader>
      
      <CardContent>
        <form onsubmit={handleSubmit}>
          {#if account_type === 'team'}
            <div class="space-y-2 mb-6">
              <Label for="name">Team Name</Label>
              <Input 
                id="name"
                bind:value={accountName}
                placeholder="My Awesome Team"
                required
                class:border-destructive={errors.name}
              />
              {#if errors.name}
                <p class="text-sm text-destructive">{errors.name[0]}</p>
              {/if}
            </div>
          {/if}
          
          <div class="flex gap-3">
            <Button type="button" variant="outline" onclick={() => router.visit(accountsPath())}>
              Cancel
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting ? 'Creating...' : 'Create Account'}
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  </div>
  ```

### Phase 4: Enhanced Registration Flow

- [ ] **Update Registration Controller** (`app/controllers/registrations_controller.rb`)
  ```ruby
  # Modify the register_user method to not auto-create personal account
  def register_user
    user = User.find_or_initialize_by(email_address: normalized_email)
    was_new_user = !user.persisted?
    
    if user.persisted?
      # Existing user - check if they have any memberships
      if user.memberships.any?
        membership = user.memberships.first
        membership.resend_confirmation! unless membership.confirmed?
      else
        # User exists but has no accounts (edge case)
        create_initial_personal_account(user)
      end
    else
      # New user - create with personal account by default
      user.save!(validate: false) # Skip password validation
      create_initial_personal_account(user)
    end
    
    # Track if this was a new user
    user.define_singleton_method(:was_new_record?) { was_new_user }
    redirect_with_confirmation_sent(was_new_user)
    true
  rescue ActiveRecord::RecordInvalid => e
    @registration_errors = e.record.errors.to_hash(true)
    false
  end
  
  private
  
  def create_initial_personal_account(user)
    account = Account.create!(
      name: "#{user.email_address}'s Account",
      account_type: :personal
    )
    
    user.memberships.create!(
      account: account,
      role: "owner"
    )
  end
  ```

- [ ] **Handle Team Invitations Without Personal Account** (`app/controllers/invitations_controller.rb`)
  ```ruby
  # When accepting a team invitation, check if user needs onboarding
  def accept
    membership = Membership.confirm_by_token!(params[:token])
    user = membership.user
    
    if user.password_digest?
      # Existing user with password
      start_authenticated_session(user)
      redirect_to account_path(membership.account), 
        notice: "Welcome to #{membership.account.name}!"
    else
      # New user needs password setup
      session[:pending_password_user_id] = user.id
      redirect_to set_password_path, 
        notice: "Welcome! Please set your password to continue."
    end
  end
  ```

### Phase 5: Account Context Handling

- [ ] **Update AccountScoping Concern** (`app/controllers/concerns/account_scoping.rb`)
  ```ruby
  def current_account
    @current_account ||= if params[:account_id]
      Current.user&.accounts&.find(params[:account_id])
    elsif params[:id] && controller_name == 'accounts'
      Current.user&.accounts&.find(params[:id])
    else
      Current.user&.default_account
    end
  end
  
  # Add method to require account context
  def require_account_context
    unless current_account
      redirect_to accounts_path, 
        alert: "Please select an account to continue"
    end
  end
  ```

### Phase 6: Testing Strategy

- [ ] **Model Tests** (`test/models/`)
  - Test personal account limit (only one per user)
  - Test team account creation and membership
  - Test invitation flows without personal accounts
  - Test account switching logic

- [ ] **Controller Tests** (`test/controllers/`)
  - Test account creation (personal and team)
  - Test account switching redirects
  - Test authorization for account access
  - Test invitation acceptance flows

- [ ] **Integration Tests** (`test/system/`)
  - Test complete user journey from signup
  - Test team invitation acceptance
  - Test account switcher UI
  - Test creating personal account after joining team

- [ ] **Edge Cases to Test**
  - User invited to team before having personal account
  - Attempting to create second personal account
  - Switching between accounts with different resources
  - Deleting last owner from team account

## Potential Edge Cases and Error Handling

1. **Personal Account Limits**
   - Validation prevents multiple personal accounts
   - Clear error messages when limit reached
   - UI hides "Create Personal Account" when not allowed

2. **Team Invitations**
   - Users without passwords get onboarding flow
   - Expired tokens handled gracefully
   - Duplicate invitations prevented

3. **Account Switching**
   - Invalid account IDs return 404
   - Authorization checked on every request
   - Smart redirects preserve user context

4. **Orphaned Users**
   - Users with no accounts get prompted to create one
   - Deleted accounts don't leave users stranded
   - Clear path to account creation always available

## Migration Considerations

1. **Existing Data**
   - Current users already have accounts (personal or team)
   - No data migration needed, just behavior changes
   - Backward compatible with existing account structure

2. **Feature Flags**
   - Consider gradual rollout with feature flags
   - Test with subset of users first
   - Easy rollback if issues discovered

## Performance Optimizations

1. **Database Queries**
   - Use `includes` for account switcher queries
   - Cache user's account list in Redis if needed
   - Optimize N+1 queries in account listings

2. **Frontend**
   - Lazy load account management pages
   - Cache account list in Svelte store
   - Use optimistic UI updates for switching

## Security Considerations

1. **Authorization**
   - All account access through user.accounts association
   - RecordNotFound exceptions for unauthorized access
   - No direct Account.find without scoping

2. **Audit Logging**
   - Log all account creations and deletions
   - Track account switches if needed
   - Monitor for suspicious patterns

## Future Enhancements

1. **Account Limits**
   - Max team accounts per user
   - Account quotas based on plan

2. **Account Features**
   - Account-level settings and preferences
   - Custom account roles beyond owner/admin/member
   - Account templates for quick setup

3. **Billing Integration**
   - Per-account billing
   - Account usage tracking
   - Subscription management

This implementation maintains the Rails Way philosophy, uses RESTful routes, and provides a clean, minimal interface for multi-account support while preserving all existing functionality.