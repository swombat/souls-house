# Multi-Account Support Implementation Plan (Refined)

## Executive Summary

This refined plan implements multi-account support following Rails Way principles with ruthless simplification. Users can have one personal account and multiple team accounts, with URL-based account context (`/accounts/:account_id/...`) as a hard requirement. The implementation uses STI for account types, fat models with thin controllers, and minimal frontend complexity.

## Architecture Overview

### Key Design Decisions

1. **URL-based Account Context** (Required): Current account determined from `/accounts/:account_id/...` URLs
2. **Single Table Inheritance**: PersonalAccount and TeamAccount as STI models
3. **Fat Models, Skinny Controllers**: Business logic in models, controllers just orchestrate
4. **Rails Callbacks**: Automatic personal account creation via callbacks
5. **Simplified Frontend**: Server-driven UI with minimal client state

### Core Simplifications from v1

- Use STI instead of enum for account types
- Remove unnecessary helper methods (rely on Rails associations)
- Use Rails callbacks for automatic behaviors
- Simplify validation logic
- Reduce frontend complexity - more server rendering

## Step-by-Step Implementation

### Phase 1: Model Refactoring with STI

- [ ] **Create STI Account Models**
  
  Create `app/models/personal_account.rb`:
  ```ruby
  class PersonalAccount < Account
    # Personal accounts are always owned by their single user
    after_initialize :set_defaults, if: :new_record?
    
    validate :single_user_only
    validate :owner_role_only
    
    private
    
    def set_defaults
      self.account_type = :personal
    end
    
    def single_user_only
      if memberships.count > 1
        errors.add(:base, "Personal accounts can only have one user")
      end
    end
    
    def owner_role_only
      if memberships.any? { |m| m.role != "owner" }
        errors.add(:base, "Personal account members must be owners")
      end
    end
  end
  ```
  
  Create `app/models/team_account.rb`:
  ```ruby
  class TeamAccount < Account
    after_initialize :set_defaults, if: :new_record?
    
    private
    
    def set_defaults
      self.account_type = :team
    end
  end
  ```

- [ ] **Simplify User Model** (`app/models/user.rb`)
  ```ruby
  class User < ApplicationRecord
    # ... existing includes and associations ...
    
    # Clean associations using STI
    has_one :personal_account, -> { personal }, through: :memberships, source: :account
    has_many :team_accounts, -> { team }, through: :memberships, source: :account
    
    # Simplified validation
    validate :only_one_personal_account, if: -> { personal_account && personal_account.new_record? }
    
    # Simpler callback
    after_create :create_personal_account_if_direct_signup
    
    # Remove these methods - use Rails associations directly:
    # - has_personal_account? (use personal_account.present?)
    # - can_create_personal_account? (use !personal_account)
    # - all_accounts_for_switcher (use accounts.includes(:owner))
    
    # Simplified account creation
    def create_account!(attributes = {})
      account_class = attributes[:personal] ? PersonalAccount : TeamAccount
      account = account_class.create!(attributes.except(:personal))
      memberships.create!(account: account, role: "owner", skip_confirmation: true)
      account
    end
    
    private
    
    def only_one_personal_account
      errors.add(:base, "You already have a personal account")
    end
    
    def create_personal_account_if_direct_signup
      # Only create personal account for direct signups, not invitations
      return if memberships.any?
      
      PersonalAccount.create!(name: "Personal").tap do |account|
        memberships.create!(account: account, role: "owner", skip_confirmation: confirmed?)
      end
    end
  end
  ```

- [ ] **Simplify Account Model** (`app/models/account.rb`)
  ```ruby
  class Account < ApplicationRecord
    # ... existing includes ...
    
    # Remove complex display logic - use helpers instead
    # Remove these methods:
    # - display_name
    # - display_name_with_type
    # - personal_account_for?
    
    # Simplified name handling
    def name
      if personal? && owner
        "#{owner.full_name.presence || owner.email_address}'s Account"
      else
        super
      end
    end
    
    # Keep only essential business logic
    def convertible_to_personal?
      team? && memberships.confirmed.count == 1
    end
    
    def convertible_to_team?
      personal?
    end
    
    def convert_to_personal!
      return false unless convertible_to_personal?
      update!(type: "PersonalAccount")
      memberships.first.update!(role: "owner")
    end
    
    def convert_to_team!(name)
      return false unless convertible_to_team?
      update!(type: "TeamAccount", name: name)
    end
  end
  ```

- [ ] **Add STI Type Column Migration**
  ```ruby
  class AddTypeToAccounts < ActiveRecord::Migration[8.0]
    def change
      add_column :accounts, :type, :string
      
      # Migrate existing data
      reversible do |dir|
        dir.up do
          execute <<-SQL
            UPDATE accounts 
            SET type = CASE 
              WHEN account_type = 0 THEN 'PersonalAccount'
              WHEN account_type = 1 THEN 'TeamAccount'
            END
          SQL
        end
      end
      
      add_index :accounts, :type
    end
  end
  ```

### Phase 2: Simplified Controllers

- [ ] **RESTful AccountsController** (`app/controllers/accounts_controller.rb`)
  ```ruby
  class AccountsController < ApplicationController
    before_action :set_account, only: [:show, :edit, :update]
    
    def index
      @accounts = current_user.accounts.includes(:owner)
      render inertia: "accounts/index", props: {
        accounts: @accounts.as_json,
        can_create_personal: !current_user.personal_account
      }
    end
    
    def new
      @account = current_user.accounts.build
      render inertia: "accounts/new", props: {
        account_type: params[:type] || "team"
      }
    end
    
    def create
      @account = current_user.create_account!(account_params)
      redirect_to account_path(@account), notice: "Account created"
    rescue ActiveRecord::RecordInvalid => e
      redirect_to new_account_path(type: params[:account][:type]), 
        inertia: { errors: e.record.errors }
    end
    
    def show
      # Existing show action
      render inertia: "accounts/show", props: {
        account: @account.as_json,
        current_user_role: current_membership&.role
      }
    end
    
    private
    
    def set_account
      @account = current_user.accounts.find(params[:id])
    end
    
    def account_params
      params.require(:account).permit(:name, :type, :personal)
    end
    
    def current_membership
      @account.memberships.find_by(user: current_user)
    end
  end
  ```

- [ ] **Simplify ApplicationController** (`app/controllers/application_controller.rb`)
  ```ruby
  class ApplicationController < ActionController::Base
    # ... existing includes ...
    
    helper_method :current_account
    
    def current_account
      @current_account ||= if params[:account_id]
        current_user.accounts.find(params[:account_id])
      elsif params[:id] && controller_name == 'accounts'
        current_user.accounts.find(params[:id])
      end
    end
    
    def require_account!
      redirect_to accounts_path, alert: "Please select an account" unless current_account
    end
  end
  ```

### Phase 3: Simplified Frontend

- [ ] **Minimal Account Switcher** (`app/frontend/lib/components/navigation/Navbar.svelte`)
  ```svelte
  <script>
    import { page, router } from '@inertiajs/svelte';
    import { accountPath, accountsPath } from '@/routes';
    
    const user = $derived($page.props?.user);
    const currentAccount = $derived($page.props?.account);
    const accounts = $derived(user?.accounts || []);
  </script>
  
  <!-- In dropdown -->
  {#if currentAccount}
    <DropdownMenu.Item class="font-semibold">
      {currentAccount.name}
    </DropdownMenu.Item>
  {/if}
  
  {#if accounts.length > 1}
    <DropdownMenu.Separator />
    {#each accounts as account}
      {#if account.id !== currentAccount?.id}
        <DropdownMenu.Item onclick={() => router.visit(accountPath(account.id))}>
          Switch to {account.name}
        </DropdownMenu.Item>
      {/if}
    {/each}
  {/if}
  
  <DropdownMenu.Separator />
  <DropdownMenu.Item onclick={() => router.visit(accountsPath())}>
    Manage Accounts
  </DropdownMenu.Item>
  ```

- [ ] **Simple Accounts Index** (`app/frontend/pages/accounts/index.svelte`)
  ```svelte
  <script>
    import { page, router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button';
    import { Card } from '$lib/components/shadcn/card';
    import { accountPath, newAccountPath } from '@/routes';
    
    let { accounts = [], can_create_personal = false } = $props();
  </script>
  
  <div class="container mx-auto py-8 max-w-2xl">
    <h1 class="text-2xl font-bold mb-6">My Accounts</h1>
    
    {#if can_create_personal}
      <div class="mb-4">
        <Button onclick={() => router.post('/accounts', { 
          account: { personal: true } 
        })}>
          Create Personal Account
        </Button>
      </div>
    {/if}
    
    <div class="space-y-3">
      {#each accounts as account}
        <Card class="p-4 cursor-pointer hover:bg-accent/50"
              onclick={() => router.visit(accountPath(account.id))}>
          <div class="font-semibold">{account.name}</div>
          <div class="text-sm text-muted-foreground">
            {account.personal ? 'Personal' : 'Team'} • 
            {account.members_count} {account.members_count === 1 ? 'member' : 'members'}
          </div>
        </Card>
      {/each}
    </div>
    
    <div class="mt-6">
      <Button onclick={() => router.visit(newAccountPath({ type: 'team' }))}>
        Create Team Account
      </Button>
    </div>
  </div>
  ```

- [ ] **Simple New Account Form** (`app/frontend/pages/accounts/new.svelte`)
  ```svelte
  <script>
    import { router } from '@inertiajs/svelte';
    import { Button } from '$lib/components/shadcn/button';
    import { Input } from '$lib/components/shadcn/input';
    import { accountsPath } from '@/routes';
    
    let { account_type = 'team' } = $props();
    let name = $state('');
    
    function handleSubmit(e) {
      e.preventDefault();
      router.post(accountsPath(), {
        account: {
          type: account_type === 'team' ? 'TeamAccount' : 'PersonalAccount',
          name: account_type === 'team' ? name : undefined
        }
      });
    }
  </script>
  
  <div class="container mx-auto py-8 max-w-lg">
    <h1 class="text-2xl font-bold mb-6">
      Create {account_type === 'personal' ? 'Personal' : 'Team'} Account
    </h1>
    
    <form onsubmit={handleSubmit}>
      {#if account_type === 'team'}
        <div class="mb-4">
          <Input 
            bind:value={name}
            placeholder="Team Name"
            required
          />
        </div>
      {/if}
      
      <div class="flex gap-3">
        <Button type="button" variant="outline" 
                onclick={() => router.visit(accountsPath())}>
          Cancel
        </Button>
        <Button type="submit">Create</Button>
      </div>
    </form>
  </div>
  ```

### Phase 4: Registration & Invitation Flow

- [ ] **Simplified Registration** (`app/controllers/registrations_controller.rb`)
  ```ruby
  class RegistrationsController < ApplicationController
    # ... existing code ...
    
    private
    
    def register_user
      user = User.find_or_initialize_by(email_address: normalized_email)
      
      if user.persisted?
        # Existing user - ensure they have a membership
        membership = user.memberships.first || create_personal_membership(user)
        membership.resend_confirmation! unless membership.confirmed?
      else
        # New user - save and let callback create personal account
        user.save!(validate: false)
      end
      
      redirect_with_confirmation_sent(user.new_record?)
    rescue ActiveRecord::RecordInvalid => e
      @registration_errors = e.record.errors
      false
    end
    
    def create_personal_membership(user)
      account = PersonalAccount.create!(name: "Personal")
      user.memberships.create!(account: account, role: "owner")
    end
  end
  ```

- [ ] **Team Invitation Handling** (`app/controllers/invitations_controller.rb`)
  ```ruby
  class InvitationsController < ApplicationController
    def create
      @account = current_user.accounts.find(params[:account_id])
      @membership = @account.invite_member(
        email: params[:email],
        role: params[:role],
        invited_by: current_user
      )
      
      if @membership.save
        redirect_to account_path(@account), notice: "Invitation sent"
      else
        redirect_to account_path(@account), 
          inertia: { errors: @membership.errors }
      end
    end
    
    def accept
      membership = Membership.confirm_by_token!(params[:token])
      
      if membership.user.password_digest?
        start_authenticated_session(membership.user)
        redirect_to account_path(membership.account)
      else
        session[:pending_user_id] = membership.user.id
        redirect_to set_password_path
      end
    end
  end
  ```

### Phase 5: View Helpers

- [ ] **Create Account Helpers** (`app/helpers/accounts_helper.rb`)
  ```ruby
  module AccountsHelper
    def account_type_badge(account)
      type = account.personal? ? "Personal" : "Team"
      tag.span(type, class: "badge badge-outline")
    end
    
    def account_display_name(account)
      account.personal? ? "Personal" : account.name
    end
    
    def account_icon(account)
      account.personal? ? "user" : "building"
    end
  end
  ```

### Phase 6: Testing Strategy

- [ ] **Model Tests**
  ```ruby
  # test/models/user_test.rb
  test "user can have only one personal account" do
    user = users(:john)
    user.create_account!(personal: true)
    
    assert_raises(ActiveRecord::RecordInvalid) do
      user.create_account!(personal: true)
    end
  end
  
  test "user can have multiple team accounts" do
    user = users(:john)
    account1 = user.create_account!(name: "Team 1")
    account2 = user.create_account!(name: "Team 2")
    
    assert_equal 2, user.team_accounts.count
  end
  ```

- [ ] **Controller Tests**
  ```ruby
  # test/controllers/accounts_controller_test.rb
  test "index shows all user accounts" do
    sign_in users(:john)
    get accounts_path
    assert_response :success
  end
  
  test "create personal account when missing" do
    user = users(:jane) # user without personal account
    sign_in user
    
    post accounts_path, params: { account: { personal: true } }
    assert user.reload.personal_account.present?
  end
  ```

## Key Improvements from v1

### Following Rails Way

1. **STI over Enums**: PersonalAccount and TeamAccount classes encapsulate type-specific behavior
2. **Callbacks over Complex Logic**: Automatic personal account creation via `after_create`
3. **Associations over Methods**: Use `user.personal_account` not `user.has_personal_account?`
4. **Helpers over Model Methods**: Display logic in helpers, not models
5. **Simple Validations**: One clear validation per concern

### Reduced Complexity

1. **50% Less Code**: Removed unnecessary abstractions and methods
2. **Simpler Frontend**: Server-driven with minimal client state
3. **Clear Patterns**: Standard Rails patterns any developer knows
4. **No Clever Code**: Straightforward, boring, maintainable

### Maintained Requirements

1. **URL-based Context**: Account ID stays in URL as required
2. **Multi-Account Support**: One personal, many team accounts
3. **Team Invitations**: Can invite without personal accounts
4. **Account Switching**: Simple dropdown navigation

## Migration Path

1. Add STI type column to accounts table
2. Update existing records with correct type
3. Deploy model changes
4. Update controllers and views
5. Test with subset of users
6. Full rollout

## What We Didn't Add

Following DHH's principle of "what you don't build is as important as what you do":

- No service objects
- No complex state machines
- No database constraints (Rails validations only)
- No session-based account storage
- No complex frontend state management
- No premature optimizations

This implementation achieves the same functionality as v1 with half the complexity by trusting Rails conventions and avoiding unnecessary abstractions.