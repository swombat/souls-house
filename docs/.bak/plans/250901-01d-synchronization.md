# Real-time Synchronization for Svelte/Inertia - Final Implementation

## Executive Summary

This final specification implements real-time synchronization for Rails 8 + Svelte 5 + Inertia.js applications. Based on reviewer feedback, this version includes:

1. **Clean `useSync` abstraction** - Components only call `useSync()` without worrying about lifecycle or ActionCable
2. **Simplified account-based permissions** - All permissioned objects belong to an account; everyone in an account sees updates for that account's objects
3. **Admin-only access** for objects without account property

## Core Architecture

### Data Flow

```
Model Update → Broadcast Marker → ActionCable → useSync Hook → Debounced Inertia Reload
```

### Design Principles

1. **Minimal component boilerplate** - Just call `useSync()` with mappings
2. **Account-scoped permissions** - Simple, clear authorization model
3. **Rails conventions** - Fat models, declarative APIs
4. **Hidden implementation details** - Components don't know about ActionCable
5. **Functional JavaScript** - No shared mutable state

## Rails Implementation

### 1. ActionCable Connection

Simple session-based authentication:

```ruby
# app/channels/application_cable/connection.rb
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      if session = Session.find_by(id: cookies.signed[:session_id])
        session.user
      else
        reject_unauthorized_connection
      end
    end
  end
end
```

### 2. Simplified Authorization Model

All models either have an account or are admin-only:

```ruby
# app/models/concerns/sync_authorizable.rb
module SyncAuthorizable
  extend ActiveSupport::Concern

  module ClassMethods
    def accessible_by(user)
      return none unless user
      
      # If model has account association, use account-based access
      if reflect_on_association(:account)
        return all if user.site_admin?
        joins(:account).where(account: user.accounts)
      else
        # No account means admin-only
        user.site_admin? ? all : none
      end
    end
  end
end
```

### 3. Updated Models

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  include ObfuscatesId
  include SyncAuthorizable
  include Broadcastable
  
  has_many :account_users
  has_many :users, through: :account_users
  
  # Account is special - it IS the account
  def self.accessible_by(user)
    return none unless user
    return all if user.site_admin?
    user.accounts
  end
  
  # Broadcasting configuration
  broadcasts_to :all # Admin collection
  broadcasts_refresh_prop :account
  broadcasts_refresh_prop :accounts, collection: true
end

# app/models/account_user.rb  
class AccountUser < ApplicationRecord
  include ObfuscatesId
  include SyncAuthorizable  
  include Broadcastable
  
  belongs_to :account
  belongs_to :user
  
  # Broadcasting configuration
  broadcasts_to parent: :account
  broadcasts_refresh_prop :account # Refresh parent's prop
end

# app/models/system_setting.rb (example admin-only model)
class SystemSetting < ApplicationRecord
  include ObfuscatesId
  include SyncAuthorizable
  include Broadcastable
  
  # No account association = admin only
  
  broadcasts_to :all
  broadcasts_refresh_prop :system_settings, collection: true
end
```

### 4. SyncChannel with Simplified Auth

```ruby
# app/channels/sync_channel.rb
class SyncChannel < ApplicationCable::Channel
  def subscribed
    model_class = params[:model].safe_constantize
    return reject unless model_class
    
    if params[:id] == "all"
      # Collection subscription - check if user can access any
      if model_class.accessible_by(current_user).any?
        stream_from "#{params[:model]}:all"
      else
        reject
      end
    elsif params[:id]
      # Single object subscription
      record = model_class.accessible_by(current_user)
                         .find_by_obfuscated_id(params[:id])
      if record
        stream_from "#{params[:model]}:#{params[:id]}"
      else
        reject
      end
    else
      reject
    end
  end
end
```

### 5. Broadcastable Concern (unchanged from v3)

```ruby
# app/models/concerns/broadcastable.rb
module Broadcastable
  extend ActiveSupport::Concern

  included do
    after_commit :broadcast_refresh, on: [:create, :update]
    after_commit :broadcast_removal, on: :destroy
    
    class_attribute :broadcast_targets, default: []
    class_attribute :refresh_props, default: {}
  end

  private

  def broadcast_refresh
    # Broadcast to self
    broadcast_marker("#{self.class.name}:#{obfuscated_id}", 
                    action: "refresh",
                    prop: self.class.refresh_props[:single] || model_prop_name)
    
    # Broadcast to configured targets
    self.class.broadcast_targets.each do |target|
      case target
      when :all
        broadcast_marker("#{self.class.name}:all",
                        action: "refresh", 
                        prop: self.class.refresh_props[:collection] || model_prop_name.pluralize)
      when Hash
        if target[:parent] && (parent = send(target[:parent]))
          broadcast_marker("#{parent.class.name}:#{parent.obfuscated_id}",
                          action: "refresh",
                          prop: self.class.refresh_props[:parent] || parent.class.name.underscore)
        end
      end
    end
  end
  
  def broadcast_removal
    broadcast_marker("#{self.class.name}:#{obfuscated_id}", 
                    action: "remove",
                    prop: self.class.refresh_props[:single] || model_prop_name)
    
    # Also broadcast removal to collections
    self.class.broadcast_targets.each do |target|
      case target
      when :all
        broadcast_marker("#{self.class.name}:all",
                        action: "remove",
                        prop: self.class.refresh_props[:collection] || model_prop_name.pluralize)
      when Hash
        if target[:parent] && (parent = send(target[:parent]))
          broadcast_marker("#{parent.class.name}:#{parent.obfuscated_id}",
                          action: "refresh",
                          prop: self.class.refresh_props[:parent] || parent.class.name.underscore)
        end
      end
    end
  end
  
  def broadcast_marker(channel, data)
    ActionCable.server.broadcast(channel, data)
  end
  
  def model_prop_name
    self.class.name.underscore
  end

  module ClassMethods
    def broadcasts_to(*targets)
      self.broadcast_targets = targets
    end
    
    def broadcasts_refresh_prop(name, collection: false, parent: false)
      if collection
        self.refresh_props = refresh_props.merge(collection: name.to_s)
      elsif parent  
        self.refresh_props = refresh_props.merge(parent: name.to_s)
      else
        self.refresh_props = refresh_props.merge(single: name.to_s)
      end
    end
  end
end
```

## JavaScript Implementation with useSync Abstraction

### 1. Core Cable Module (Hidden from Components)

```javascript
// app/frontend/lib/cable.js
import { createConsumer } from '@rails/actioncable';
import { router } from '@inertiajs/svelte';
import { browser } from '$app/environment';

// Create consumer once
const consumer = browser ? createConsumer() : null;

// Pure debounce function
function debounce(fn, delay) {
  let timeoutId;
  let pendingProps = new Set();
  
  return (props) => {
    // Accumulate props
    props.forEach(prop => pendingProps.add(prop));
    
    clearTimeout(timeoutId);
    timeoutId = setTimeout(() => {
      if (pendingProps.size > 0) {
        fn(Array.from(pendingProps));
        pendingProps.clear();
      }
    }, delay);
  };
}

// Global debounced reload (shared across all subscriptions)
const reloadProps = debounce((props) => {
  console.log('Reloading props:', props);
  router.reload({
    only: props,
    preserveState: true,
    preserveScroll: true
  });
}, 300);

/**
 * Internal function to subscribe to model updates
 * @private
 */
export function subscribeToModel(model, id, props) {
  if (!browser || !consumer) return () => {};
  
  const subscription = consumer.subscriptions.create(
    { 
      channel: 'SyncChannel', 
      model,
      id
    },
    {
      connected() {
        console.log(`Sync connected: ${model}:${id}`);
      },
      
      received(data) {
        console.log(`Sync received: ${model}:${id}`, data);
        
        // Use explicit prop from server or fallback to provided props
        const propsToReload = data.prop ? [data.prop] : props;
        reloadProps(propsToReload);
      },
      
      disconnected() {
        console.log(`Sync disconnected: ${model}:${id}`);
      }
    }
  );
  
  return () => subscription.unsubscribe();
}
```

### 2. The useSync Hook - Clean Component API

```javascript
// app/frontend/lib/use-sync.js
import { onMount, onDestroy } from 'svelte';
import { subscribeToModel } from './cable';

/**
 * Hook to synchronize Svelte components with Rails models via ActionCable
 * 
 * @param {Object} subscriptions - Map of subscriptions
 * @example
 * useSync({
 *   'Account:abc123': 'account',
 *   'Account:all': 'accounts',
 *   'Account:abc123/account_users': 'account'
 * })
 */
export function useSync(subscriptions) {
  const unsubscribers = [];
  
  onMount(() => {
    Object.entries(subscriptions).forEach(([key, prop]) => {
      // Parse the subscription key
      const match = key.match(/^([A-Z]\w+):([^\/]+)(\/.*)?$/);
      if (!match) {
        console.warn(`Invalid subscription key: ${key}`);
        return;
      }
      
      const [, model, id, collection] = match;
      const props = Array.isArray(prop) ? prop : [prop];
      
      // Create subscription
      const unsubscribe = subscribeToModel(model, id, props);
      unsubscribers.push(unsubscribe);
      
      // If there's a collection suffix, subscribe to that too
      if (collection) {
        // This handles cases like 'Account:abc123/account_users'
        // The broadcast will still come on 'Account:abc123' channel
        // but we know to reload the specified prop
      }
    });
  });
  
  onDestroy(() => {
    unsubscribers.forEach(unsub => unsub());
  });
}
```

## Usage Examples - Minimal Boilerplate

### Single Account Page

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { account } = $props();
  
  // That's it! No onMount, no onDestroy, no ActionCable knowledge needed
  useSync({
    [`Account:${account.id}`]: 'account'
  });
</script>

<div>
  <h1>{account.name}</h1>
  <p>Members: {account.members_count}</p>
</div>
```

### Admin Dashboard with Collections

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { accounts = [], selected_account = null } = $props();
  
  // Build subscriptions dynamically
  const subs = {
    'Account:all': 'accounts'
  };
  
  if (selected_account) {
    subs[`Account:${selected_account.id}`] = 'selected_account';
    subs[`Account:${selected_account.id}/account_users`] = 'selected_account';
  }
  
  useSync(subs);
</script>

<div class="dashboard">
  <AccountsList {accounts} />
  {#if selected_account}
    <AccountDetails account={selected_account} />
  {/if}
</div>
```

### Complex Page with Multiple Models

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { account, projects = [], current_user } = $props();
  
  useSync({
    [`Account:${account.id}`]: 'account',
    [`Account:${account.id}/projects`]: 'projects',
    [`User:${current_user.id}`]: 'current_user',
    'SystemSetting:all': 'system_settings' // Admin only
  });
</script>
```

### Dynamic Subscriptions

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { accounts = [] } = $props();
  let selectedId = $state(null);
  
  // Reactive subscriptions
  $effect(() => {
    const subs = { 'Account:all': 'accounts' };
    
    if (selectedId) {
      subs[`Account:${selectedId}`] = 'selected_account';
    }
    
    useSync(subs);
  });
</script>
```

## Controller Integration

Controllers work exactly as before:

```ruby
# app/controllers/accounts_controller.rb
class AccountsController < ApplicationController
  def show
    @account = current_user.accounts.find_by_obfuscated_id!(params[:id])
    
    render inertia: "accounts/show", props: {
      account: {
        id: @account.obfuscated_id,
        name: @account.name,
        account_type: @account.account_type,
        members_count: @account.members_count,
        account_users: @account.account_users.includes(:user).map { |au|
          {
            id: au.obfuscated_id,
            role: au.role,
            user: au.user.slice(:name, :email_address)
          }
        }
      }
    }
  end
end
```

## Testing Strategy

### Rails Tests

```ruby
# test/models/concerns/sync_authorizable_test.rb
class SyncAuthorizableTest < ActiveSupport::TestCase
  test "models with account use account-based access" do
    user = users(:john)
    account = user.accounts.first
    other_account = accounts(:competitor)
    
    # User can access their account's objects
    assert_includes AccountUser.accessible_by(user), account.account_users.first
    
    # User cannot access other account's objects
    refute_includes AccountUser.accessible_by(user), other_account.account_users.first
  end
  
  test "models without account are admin-only" do
    regular_user = users(:john)
    admin = users(:admin)
    
    assert_empty SystemSetting.accessible_by(regular_user)
    assert_not_empty SystemSetting.accessible_by(admin)
  end
  
  test "site admins can access everything" do
    admin = users(:admin)
    
    assert_equal Account.all, Account.accessible_by(admin)
    assert_equal AccountUser.all, AccountUser.accessible_by(admin)
    assert_equal SystemSetting.all, SystemSetting.accessible_by(admin)
  end
end
```

### JavaScript Tests

```javascript
// test/frontend/use-sync.test.js
import { describe, it, expect, vi } from 'vitest';
import { render, cleanup } from '@testing-library/svelte';
import { useSync } from '$lib/use-sync';

// Mock the cable module
vi.mock('$lib/cable', () => ({
  subscribeToModel: vi.fn(() => vi.fn())
}));

describe('useSync', () => {
  it('parses subscription keys correctly', () => {
    const TestComponent = {
      render: () => {
        useSync({
          'Account:abc123': 'account',
          'Account:all': 'accounts',
          'Account:xyz789/account_users': 'account'
        });
      }
    };
    
    render(TestComponent);
    
    // Verify subscribeToModel was called with correct params
    const { subscribeToModel } = await import('$lib/cable');
    
    expect(subscribeToModel).toHaveBeenCalledWith('Account', 'abc123', ['account']);
    expect(subscribeToModel).toHaveBeenCalledWith('Account', 'all', ['accounts']);
    expect(subscribeToModel).toHaveBeenCalledWith('Account', 'xyz789', ['account']);
  });
  
  it('cleans up subscriptions on unmount', async () => {
    const unsubscribe = vi.fn();
    vi.mocked(subscribeToModel).mockReturnValue(unsubscribe);
    
    const { unmount } = render(TestComponent);
    unmount();
    
    expect(unsubscribe).toHaveBeenCalled();
  });
});
```

## Implementation Checklist

### Phase 1: Foundation (3 hours)
- [ ] Add SyncAuthorizable concern with account-based logic
- [ ] Update all models to include SyncAuthorizable
- [ ] Create SyncChannel with simplified authorization
- [ ] Add Broadcastable concern to models
- [ ] Test authorization with rails console

### Phase 2: JavaScript Core (2 hours)
- [ ] Create cable.js with subscribeToModel
- [ ] Implement global debounced reload
- [ ] Create useSync hook with subscription parsing
- [ ] Test with a simple component

### Phase 3: Integration (3 hours)
- [ ] Update all Svelte pages to use useSync
- [ ] Remove direct ActionCable imports from components
- [ ] Test multi-tab synchronization
- [ ] Verify parent/child broadcasting

### Phase 4: Testing & Documentation (2 hours)
- [ ] Write SyncAuthorizable tests
- [ ] Write useSync tests
- [ ] Write channel authorization tests
- [ ] Update README with usage examples

## Key Improvements in v4

### From Review Feedback

1. **useSync abstraction** - Components just call `useSync()`, no lifecycle management
2. **Simplified permissions** - Account-based for most models, admin-only for system models
3. **Hidden implementation** - Components don't know about ActionCable
4. **Cleaner API** - Single object with subscription mappings

### Maintained Requirements

- Object marker broadcasting (for Inertia, not Turbo)
- 300ms debouncing (prevents reload storms)
- Obfuscated IDs (security)
- Support for objects, collections, and nested resources
- Minimal component boilerplate

## Permission Model Summary

### Simple Rules

1. **Has `account` property?** → Everyone in that account can see updates
2. **No `account` property?** → Admin-only
3. **Site admin?** → Can see everything

This eliminates complex authorization logic while maintaining security:

```ruby
# In any model
belongs_to :account  # ← This is all you need for account-based access

# The concern handles the rest
include SyncAuthorizable
```

## Performance Notes

### Global Debouncing

The v4 implementation uses a single global debouncer shared across all subscriptions. This ensures that if multiple models update simultaneously (common in related data), only one Inertia reload occurs:

```javascript
// Multiple updates within 300ms window
Account updated → queue 'account' prop
AccountUser updated → queue 'account' prop  
Project updated → queue 'projects' prop

// After 300ms, single reload with all props
router.reload({ only: ['account', 'projects'] })
```

### Memory Management

- Subscriptions automatically cleaned up via onDestroy
- No memory leaks from forgotten unsubscribes
- Consumer created once and reused

## Security Architecture

### Three Layers of Security

1. **ActionCable connection** - Must be authenticated user
2. **Channel authorization** - Uses model's `accessible_by` scope
3. **Inertia reload** - Rails controller enforces permissions again

### No Data in Broadcasts

Broadcasts only contain:
- Action (refresh/remove)
- Prop name to reload

Actual data comes from secure Inertia reload through controller.

## Conclusion

This final implementation achieves the perfect balance:
- **For developers**: Just call `useSync()` with mappings
- **For Rails**: Simple account-based authorization model
- **For performance**: Global debouncing prevents reload storms
- **For security**: Three layers of authorization checks

The abstraction hides complexity without sacrificing functionality. Components remain clean and focused on UI, while the synchronization "just works" in the background.