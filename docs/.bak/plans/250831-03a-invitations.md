# Implementation Plan: Team Account Invitation System

## Executive Summary

This plan outlines the implementation of a comprehensive invitation system for team accounts in the Rails 8 + Svelte 5 application. The system will allow team administrators to invite new members via email, manage member roles, and view team membership status. The implementation follows Rails conventions (fat models, skinny controllers) and leverages existing patterns in the codebase.

## Architecture Overview

### Core Components
1. **Backend (Rails)**
   - Enhanced AccountUser model with invitation tracking
   - New Invitations controller for managing invites
   - AccountMembers controller for member management
   - Updated Account model with invitation business logic
   - Email notifications via AccountMailer

2. **Frontend (Svelte)**
   - Members list component with role badges
   - Inline invitation form using native dialog element
   - Member management actions (remove, resend invite)
   - Real-time validation and error handling

3. **Security & Authorization**
   - Rails association-based authorization
   - Role-based access control (owner/admin/member)
   - Secure token generation for invitations
   - Protection against duplicate invitations

## Implementation Steps

### Phase 1: Database Schema Updates

- [ ] Create migration to add invitation tracking fields
```ruby
# db/migrate/TIMESTAMP_add_invitation_fields_to_account_users.rb
class AddInvitationFieldsToAccountUsers < ActiveRecord::Migration[8.0]
  def change
    # Note: invited_at and invited_by_id already exist in the schema
    # Just need to ensure they're being used properly
    add_column :account_users, :invitation_accepted_at, :datetime
    add_index :account_users, :invitation_accepted_at
  end
end
```

### Phase 2: Model Enhancements

- [ ] Update AccountUser model with invitation scopes and methods
```ruby
# app/models/account_user.rb additions
class AccountUser < ApplicationRecord
  # Add scopes for invitation status
  scope :pending_invitations, -> { unconfirmed.where.not(invited_by_id: nil) }
  scope :accepted_invitations, -> { confirmed.where.not(invited_by_id: nil) }
  
  # Instance methods for invitation status
  def invitation_pending?
    !confirmed? && invited_by_id.present?
  end
  
  def invitation_accepted?
    confirmed? && invited_by_id.present?
  end
  
  def display_name
    if user.confirmed? && user.first_name.present?
      user.full_name
    else
      user.email_address
    end
  end
  
  def status
    if !confirmed? && invited_by_id.present?
      "invited"
    elsif confirmed?
      "active"
    else
      "pending"
    end
  end
end
```

- [ ] Add invitation business logic to Account model
```ruby
# app/models/account.rb additions
class Account < ApplicationRecord
  # Business logic for inviting users
  def invite_user!(email:, role:, invited_by:)
    raise "Only team accounts can invite users" if personal?
    raise "Invalid role" unless AccountUser::ROLES.include?(role)
    raise "Only admins and owners can invite" unless invited_by.can_manage?(self)
    
    transaction do
      # Find or create user
      user = User.find_or_initialize_by(email_address: email)
      new_user = user.new_record?
      
      if new_user
        # Create user without password (they'll set it on confirmation)
        user.save!(validate: false)
      end
      
      # Check for existing membership
      account_user = account_users.find_or_initialize_by(user: user)
      
      if account_user.persisted?
        if account_user.confirmed?
          raise "User is already a member of this account"
        else
          # Resend invitation
          account_user.resend_invitation!(invited_by)
        end
      else
        # Create new invitation
        account_user.role = role
        account_user.invited_by = invited_by
        account_user.invited_at = Time.current
        account_user.save!
      end
      
      account_user
    end
  end
  
  def remove_member!(user, removed_by:)
    raise "Only admins and owners can remove members" unless removed_by.can_manage?(self)
    raise "Cannot remove the last owner" if owners_count == 1 && user.owns?(self)
    
    account_users.find_by!(user: user).destroy!
  end
  
  def owners_count
    account_users.owners.confirmed.count
  end
  
  def members_with_details
    account_users.includes(:user, :invited_by).order(:created_at)
  end
end
```

- [ ] Update AccountUser to handle invitation resending
```ruby
# app/models/account_user.rb
def resend_invitation!(invited_by)
  update!(
    invited_by: invited_by,
    invited_at: Time.current
  )
  generate_confirmation_token
  save!
  send_confirmation_email
end
```

### Phase 3: Controllers

- [ ] Create AccountMembersController
```ruby
# app/controllers/account_members_controller.rb
class AccountMembersController < ApplicationController
  before_action :set_account
  before_action :authorize_management!, except: [:index]
  
  def index
    members = @account.members_with_details.map do |member|
      {
        id: member.id,
        user_id: member.user_id,
        email: member.user.email_address,
        name: member.display_name,
        role: member.role,
        status: member.status,
        confirmed_at: member.confirmed_at,
        invited_at: member.invited_at,
        invited_by: member.invited_by&.full_name,
        can_remove: can_remove_member?(member)
      }
    end
    
    render inertia: 'accounts/members', props: {
      account: @account,
      members: members,
      can_manage: Current.user.can_manage?(@account),
      current_user_id: Current.user.id
    }
  end
  
  def destroy
    member = @account.account_users.find(params[:id])
    @account.remove_member!(member.user, removed_by: Current.user)
    
    redirect_to account_members_path(@account), 
      notice: "Member removed successfully"
  rescue => e
    redirect_to account_members_path(@account), 
      alert: e.message
  end
  
  private
  
  def set_account
    @account = Current.user.accounts.find(params[:account_id])
  end
  
  def authorize_management!
    unless Current.user.can_manage?(@account)
      redirect_to account_path(@account), 
        alert: "You don't have permission to manage members"
    end
  end
  
  def can_remove_member?(member)
    return false unless Current.user.can_manage?(@account)
    return false if member.user_id == Current.user.id # Can't remove yourself
    return false if member.owner? && @account.owners_count == 1 # Can't remove last owner
    true
  end
end
```

- [ ] Create InvitationsController
```ruby
# app/controllers/invitations_controller.rb
class InvitationsController < ApplicationController
  before_action :set_account
  before_action :authorize_management!
  
  def create
    account_user = @account.invite_user!(
      email: params[:email],
      role: params[:role],
      invited_by: Current.user
    )
    
    redirect_to account_members_path(@account), 
      notice: "Invitation sent to #{params[:email]}"
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_members_path(@account), 
      alert: e.record.errors.full_messages.to_sentence
  rescue => e
    redirect_to account_members_path(@account), 
      alert: e.message
  end
  
  def resend
    member = @account.account_users.find(params[:id])
    member.resend_invitation!(Current.user)
    
    redirect_to account_members_path(@account), 
      notice: "Invitation resent to #{member.user.email_address}"
  rescue => e
    redirect_to account_members_path(@account), 
      alert: e.message
  end
  
  private
  
  def set_account
    @account = Current.user.accounts.find(params[:account_id])
  end
  
  def authorize_management!
    unless Current.user.can_manage?(@account)
      redirect_to account_path(@account), 
        alert: "You don't have permission to invite members"
    end
  end
end
```

### Phase 4: Routes Configuration

- [ ] Update routes.rb
```ruby
# config/routes.rb additions
resources :accounts, only: [:show, :edit, :update] do
  resources :members, controller: 'account_members', only: [:index, :destroy]
  resources :invitations, only: [:create] do
    member do
      post :resend
    end
  end
end
```

### Phase 5: Frontend Components

- [ ] Create Members page component
```svelte
<!-- app/frontend/pages/accounts/members.svelte -->
<script>
  import { page, router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button';
  import { Card, CardContent, CardHeader, CardTitle } from '$lib/components/shadcn/card';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Input } from '$lib/components/shadcn/input';
  import { Label } from '$lib/components/shadcn/label';
  import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '$lib/components/shadcn/select';
  import { UserPlus, Users, Mail, Trash2, RefreshCw } from 'phosphor-svelte';
  
  const { account, members, can_manage, current_user_id } = $page.props;
  
  let showInviteForm = $state(false);
  let inviteEmail = $state('');
  let inviteRole = $state('member');
  let isSubmitting = $state(false);
  
  function handleInvite(e) {
    e.preventDefault();
    if (!inviteEmail || !inviteRole) return;
    
    isSubmitting = true;
    router.post(`/accounts/${account.id}/invitations`, {
      email: inviteEmail,
      role: inviteRole
    }, {
      preserveState: false,
      onSuccess: () => {
        inviteEmail = '';
        inviteRole = 'member';
        showInviteForm = false;
      },
      onFinish: () => {
        isSubmitting = false;
      }
    });
  }
  
  function removeMember(memberId) {
    if (confirm('Are you sure you want to remove this member?')) {
      router.delete(`/accounts/${account.id}/members/${memberId}`);
    }
  }
  
  function resendInvitation(memberId) {
    router.post(`/accounts/${account.id}/invitations/${memberId}/resend`);
  }
  
  function getRoleBadgeVariant(role) {
    switch(role) {
      case 'owner': return 'destructive';
      case 'admin': return 'default';
      default: return 'secondary';
    }
  }
  
  function getStatusBadgeVariant(status) {
    switch(status) {
      case 'active': return 'default';
      case 'invited': return 'outline';
      default: return 'secondary';
    }
  }
</script>

<div class="container mx-auto p-8 max-w-6xl">
  <div class="mb-8">
    <div class="flex items-center justify-between">
      <div>
        <h1 class="text-3xl font-bold mb-2">Team Members</h1>
        <p class="text-muted-foreground">
          Manage your team members and their roles
        </p>
      </div>
      {#if can_manage}
        <Button onclick={() => showInviteForm = true} class="gap-2">
          <UserPlus class="h-4 w-4" />
          Invite Member
        </Button>
      {/if}
    </div>
  </div>
  
  <!-- Invite Form (inline) -->
  {#if showInviteForm && can_manage}
    <Card class="mb-8">
      <CardHeader>
        <CardTitle>Invite New Member</CardTitle>
      </CardHeader>
      <CardContent>
        <form onsubmit={handleInvite} class="space-y-4">
          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div>
              <Label for="email">Email Address</Label>
              <Input
                id="email"
                type="email"
                bind:value={inviteEmail}
                placeholder="colleague@example.com"
                required
                disabled={isSubmitting}
              />
            </div>
            <div>
              <Label for="role">Role</Label>
              <Select bind:value={inviteRole} disabled={isSubmitting}>
                <SelectTrigger id="role">
                  <SelectValue placeholder="Select a role" />
                </SelectTrigger>
                <SelectContent>
                  <SelectItem value="member">Member</SelectItem>
                  <SelectItem value="admin">Admin</SelectItem>
                  <SelectItem value="owner">Owner</SelectItem>
                </SelectContent>
              </Select>
            </div>
          </div>
          <div class="flex gap-2">
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting ? 'Sending...' : 'Send Invitation'}
            </Button>
            <Button 
              type="button" 
              variant="outline" 
              onclick={() => showInviteForm = false}
              disabled={isSubmitting}
            >
              Cancel
            </Button>
          </div>
        </form>
      </CardContent>
    </Card>
  {/if}
  
  <!-- Members List -->
  <Card>
    <CardHeader>
      <CardTitle class="flex items-center gap-2">
        <Users class="h-5 w-5" />
        Current Members ({members.length})
      </CardTitle>
    </CardHeader>
    <CardContent>
      <div class="divide-y">
        {#each members as member}
          <div class="py-4 flex items-center justify-between">
            <div class="flex-1">
              <div class="flex items-center gap-3">
                <div>
                  <p class="font-medium">
                    {member.name}
                    {#if member.user_id === current_user_id}
                      <span class="text-sm text-muted-foreground">(You)</span>
                    {/if}
                  </p>
                  <p class="text-sm text-muted-foreground">{member.email}</p>
                </div>
                <Badge variant={getRoleBadgeVariant(member.role)}>
                  {member.role}
                </Badge>
                <Badge variant={getStatusBadgeVariant(member.status)}>
                  {member.status}
                </Badge>
              </div>
              {#if member.invited_by}
                <p class="text-xs text-muted-foreground mt-1">
                  Invited by {member.invited_by} on {new Date(member.invited_at).toLocaleDateString()}
                </p>
              {/if}
            </div>
            
            {#if can_manage}
              <div class="flex items-center gap-2">
                {#if member.status === 'invited'}
                  <Button
                    size="sm"
                    variant="outline"
                    onclick={() => resendInvitation(member.id)}
                    class="gap-1"
                  >
                    <RefreshCw class="h-3 w-3" />
                    Resend
                  </Button>
                {/if}
                {#if member.can_remove}
                  <Button
                    size="sm"
                    variant="destructive"
                    onclick={() => removeMember(member.id)}
                    class="gap-1"
                  >
                    <Trash2 class="h-3 w-3" />
                    Remove
                  </Button>
                {/if}
              </div>
            {/if}
          </div>
        {/each}
      </div>
    </CardContent>
  </Card>
</div>
```

- [ ] Update account show page to include members link
```svelte
<!-- app/frontend/pages/accounts/show.svelte - add members section -->
<!-- Add after the existing cards -->
{#if account.team}
  <Card class="mt-8">
    <CardHeader>
      <CardTitle class="flex items-center gap-2">
        <Users class="h-5 w-5" />
        Team Members
      </CardTitle>
    </CardHeader>
    <CardContent>
      <p class="text-muted-foreground mb-4">
        Manage your team members, roles, and invitations.
      </p>
      <Button onclick={() => router.visit(`/accounts/${account.id}/members`)}>
        View Team Members
      </Button>
    </CardContent>
  </Card>
{/if}
```

### Phase 6: Email Templates

- [ ] Create team invitation email template
```erb
<!-- app/views/account_mailer/team_invitation.html.erb -->
<h2>You've been invited to join <%= @account.name %></h2>

<p>Hi <%= @user.email_address %>,</p>

<p>
  <%= @inviter.full_name %> has invited you to join their team account 
  "<%= @account.name %>" as a <%= @account_user.role %>.
</p>

<p>
  <a href="<%= @confirmation_url %>" style="display: inline-block; padding: 12px 24px; background-color: #3b82f6; color: white; text-decoration: none; border-radius: 6px;">
    Accept Invitation
  </a>
</p>

<p>
  Or copy and paste this link into your browser:<br>
  <%= @confirmation_url %>
</p>

<p>This invitation will expire in 24 hours.</p>
```

### Phase 7: Testing Strategy

- [ ] Model Tests
```ruby
# test/models/account_test.rb
test "should invite new user to team account" do
  account = accounts(:team)
  admin = users(:admin)
  
  assert_difference 'User.count' do
    assert_difference 'AccountUser.count' do
      account.invite_user!(
        email: "newuser@example.com",
        role: "member",
        invited_by: admin
      )
    end
  end
  
  new_user = User.find_by(email_address: "newuser@example.com")
  assert new_user.present?
  assert_not new_user.confirmed?
  
  membership = account.account_users.find_by(user: new_user)
  assert_equal "member", membership.role
  assert_equal admin, membership.invited_by
  assert membership.invitation_pending?
end

test "should not allow personal accounts to invite users" do
  account = accounts(:personal)
  owner = account.owner
  
  assert_raises(RuntimeError) do
    account.invite_user!(
      email: "test@example.com",
      role: "member",
      invited_by: owner
    )
  end
end

test "should not remove last owner" do
  account = accounts(:team)
  owner = account.owner
  
  assert_raises(RuntimeError) do
    account.remove_member!(owner, removed_by: owner)
  end
end
```

- [ ] Controller Tests
```ruby
# test/controllers/account_members_controller_test.rb
test "should list members for authorized users" do
  sign_in users(:admin)
  account = accounts(:team)
  
  get account_members_path(account)
  assert_response :success
end

test "should not allow members to remove other members" do
  sign_in users(:member)
  account = accounts(:team)
  other_member = account.account_users.where.not(user: users(:member)).first
  
  delete account_member_path(account, other_member)
  assert_redirected_to account_path(account)
end
```

- [ ] Integration Tests
```ruby
# test/integration/invitation_flow_test.rb
test "complete invitation flow" do
  # Admin invites new user
  sign_in users(:admin)
  account = accounts(:team)
  
  post account_invitations_path(account), params: {
    email: "newmember@example.com",
    role: "member"
  }
  assert_redirected_to account_members_path(account)
  
  # New user receives invitation
  new_user = User.find_by(email_address: "newmember@example.com")
  membership = new_user.account_users.first
  
  # User confirms invitation
  get email_confirmation_path(token: membership.confirmation_token)
  assert_redirected_to set_password_path
  
  # User sets password
  patch set_password_path, params: {
    password: "SecurePassword123",
    password_confirmation: "SecurePassword123"
  }
  
  # User is now confirmed member
  membership.reload
  assert membership.confirmed?
  assert_equal "member", membership.role
end
```

## Security Considerations

1. **Authorization Checks**
   - All actions verify user permissions via Rails associations
   - Role-based access control enforced at model level
   - Cannot remove last owner to prevent orphaned accounts

2. **Token Security**
   - Confirmation tokens expire after 24 hours
   - Tokens are invalidated after use
   - Secure random token generation

3. **Input Validation**
   - Email format validation
   - Role validation against whitelist
   - Duplicate invitation prevention

4. **Rate Limiting**
   - Consider adding rate limiting for invitation sending
   - Implement cooldown period for resending invitations

## Edge Cases Handled

1. **Inviting existing users**
   - System finds existing user by email
   - Creates new membership without creating duplicate user

2. **Re-inviting unconfirmed members**
   - Updates invitation timestamp
   - Generates new confirmation token
   - Sends updated email

3. **Removing members**
   - Prevents removing yourself
   - Prevents removing last owner
   - Soft-delete option for audit trail (future enhancement)

4. **Personal to team conversion**
   - Existing owner automatically becomes team owner
   - Can immediately invite new members

## Performance Optimizations

1. **Database Queries**
   - Use `includes` to prevent N+1 queries
   - Index on confirmation tokens for fast lookup
   - Index on invitation timestamps for filtering

2. **Frontend**
   - Lazy load member list for large teams
   - Debounce email validation
   - Cache member data with proper invalidation

## Future Enhancements

1. **Bulk Invitations**
   - CSV upload for multiple invitations
   - Copy/paste multiple emails

2. **Invitation Templates**
   - Custom invitation messages
   - Team branding in emails

3. **Advanced Permissions**
   - Granular role permissions
   - Custom role creation

4. **Audit Trail**
   - Track all membership changes
   - Activity log for team actions

5. **Invitation Analytics**
   - Track invitation acceptance rates
   - Time to acceptance metrics

## Dependencies

### Ruby Gems
- No additional gems required (uses Rails built-in features)

### NPM Packages
- No additional packages required (uses native dialog element)

### Existing Components Used
- ShadcnUI components (Button, Card, Badge, Input, Label, Select)
- Phosphor icons for UI elements
- Inertia.js for SPA navigation

## Deployment Considerations

1. **Database Migration**
   - Run migration to add invitation_accepted_at field
   - Backfill existing data if needed

2. **Email Configuration**
   - Ensure email delivery is configured in production
   - Test invitation emails in staging

3. **Environment Variables**
   - No new environment variables required
   - Uses existing mailer configuration

4. **Monitoring**
   - Monitor invitation sending rates
   - Track failed invitation deliveries
   - Alert on unusual invitation patterns