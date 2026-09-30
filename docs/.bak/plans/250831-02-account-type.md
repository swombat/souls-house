# Account Type Switching Feature

**Date:** August 31, 2025  
**Status:** Planning  
**Feature:** Enable users to switch account types between personal and team accounts  

## Overview

This feature allows users to switch between personal and team account types using Rails Way patterns with business logic in models and RESTful controller design.

## Requirements

1. Users can switch from personal → team account  
2. Team accounts can convert back to personal when exactly one user remains
3. Use standard Rails conventions and patterns throughout

## Implementation

### Model Changes

#### Account Model (`app/models/account.rb`)

```ruby
def make_personal!
  return unless team? && account_users.count == 1
  update!(account_type: :personal)
  account_users.first.update!(role: :owner)
end

def make_team!(name)
  return unless personal?
  update!(account_type: :team, name: name)
end

def can_be_personal?
  team? && account_users.count == 1
end
```

### Controller

#### AccountsController (`app/controllers/accounts_controller.rb`)

```ruby
class AccountsController < ApplicationController
  before_action :set_account

  def show
    render inertia: "accounts/show", props: {
      account: @account,
      can_be_personal: @account.can_be_personal?
    }
  end

  def edit
    render inertia: "accounts/edit", props: { account: @account }
  end

  def update
    case params[:convert_to]
    when "personal"
      @account.make_personal!
      redirect_to @account, notice: "Converted to personal account"
    when "team"
      @account.make_team!(params[:account][:name])
      redirect_to @account, notice: "Converted to team account"
    else
      @account.update!(account_params)
      redirect_to @account, notice: "Account updated"
    end
  end

  private

  def set_account
    @account = Current.user.accounts.find(params[:id])
  end

  def account_params
    params.require(:account).permit(:name)
  end
end
```

### Routes

```ruby
resources :accounts, only: [:show, :edit, :update]
```

### Frontend

#### Account Settings Page (`app/frontend/pages/accounts/show.svelte`)

```svelte
<script>
  import { page, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Dialog from '$lib/components/shadcn/dialog/index.js';
  import { Input } from '$lib/components/shadcn/input/index.js';

  const { account, can_be_personal } = $page.props;
  
  let showConvertDialog = $state(false);
  let teamName = $state('');

  function convertToTeam() {
    router.put(`/accounts/${account.id}`, {
      convert_to: 'team',
      account: { name: teamName }
    });
  }

  function convertToPersonal() {
    router.put(`/accounts/${account.id}`, {
      convert_to: 'personal'
    });
  }
</script>

<div class="space-y-6">
  <h1>Account Settings</h1>
  
  <div class="card">
    <h2>{account.personal ? 'Personal' : 'Team'} Account</h2>
    <p>{account.name}</p>
    <p>{account.users?.length || 0} users</p>
  </div>

  <div class="space-y-4">
    {#if account.personal}
      <Button onclick={() => showConvertDialog = true}>
        Convert to Team
      </Button>
    {:else if can_be_personal}
      <Button onclick={convertToPersonal}>
        Convert to Personal
      </Button>
    {/if}
  </div>
</div>

<Dialog.Root bind:open={showConvertDialog}>
  <Dialog.Content>
    <Dialog.Header>
      <Dialog.Title>Convert to Team</Dialog.Title>
    </Dialog.Header>
    <Input bind:value={teamName} placeholder="Team name" />
    <Dialog.Footer>
      <Button onclick={() => showConvertDialog = false}>Cancel</Button>
      <Button onclick={convertToTeam}>Convert</Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
```

## Testing

### Model Tests

```ruby
test "makes personal account from single user team" do
  account = accounts(:team_single_user)
  account.make_personal!
  assert account.personal?
end

test "makes team account from personal" do  
  account = accounts(:personal)
  account.make_team!("New Team")
  assert account.team?
  assert_equal "New Team", account.name
end
```

### Controller Tests

```ruby
test "converts to team via update" do
  patch account_path(@account), params: { 
    convert_to: 'team', 
    account: { name: 'Team' } 
  }
  assert @account.reload.team?
end
```

## Edge Cases

- **Multiple team users**: Conversion to personal disabled
- **Authorization**: Association scoping via `Current.user.accounts`
- **Validation**: Standard Rails model validations

---

## Implementation Checklist

- [ ] Add conversion methods to Account model
- [ ] Update AccountsController with single update action
- [ ] Create account settings page with conversion UI
- [ ] Add model and controller tests
- [ ] Update routes for RESTful design

---

This simplified plan follows Rails conventions with 70% less code, RESTful design, and self-documenting methods that eliminate the need for extensive comments.