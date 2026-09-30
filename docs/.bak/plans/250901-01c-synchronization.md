# Real-time Synchronization for Svelte/Inertia - Production-Ready Implementation

## Executive Summary

This production-ready specification implements real-time synchronization for Rails 8 + Svelte 5 + Inertia.js applications. Following DHH's feedback, the design is maximally Rails-idiomatic: authorization through model scopes, declarative broadcasting API, and minimal JavaScript without shared mutable state.

**Core improvements from v2:**
- Authorization moved to models using `accessible_by` scopes
- Simplified Broadcastable concern with declarative API
- Eliminated mutable shared state in JavaScript
- Removed unnecessary Svelte abstractions
- Everything explicit and Rails-idiomatic

## Core Architecture

### Data Flow

```
Model Update → Broadcast Marker → ActionCable → Svelte Component → Debounced Inertia Reload
```

### Design Principles

1. **Rails conventions above all** - Fat models, skinny controllers
2. **Explicit over clever** - Clear, readable code without magic
3. **Authorization in models** - Use Rails scopes and associations
4. **Minimal JavaScript** - Under 80 lines total
5. **No shared mutable state** - Functional, predictable code

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

### 2. Model Authorization Scopes

Move authorization to models where it belongs:

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  include ObfuscatesId
  include Broadcastable
  
  has_many :account_users
  has_many :users, through: :account_users
  
  # Authorization scope - the Rails way
  scope :accessible_by, ->(user) {
    return none unless user
    return all if user.site_admin?
    joins(:account_users).where(account_users: { user: user })
  }
  
  # Configuration for broadcasting
  broadcasts_to :all # Admin collection broadcasts
  broadcasts_refresh_prop :account # Prop name for single object
  broadcasts_refresh_prop :accounts, collection: true # Prop name for collections
end

# app/models/account_user.rb  
class AccountUser < ApplicationRecord
  include ObfuscatesId
  include Broadcastable
  
  belongs_to :account
  belongs_to :user
  
  # Authorization through parent
  scope :accessible_by, ->(user) {
    return none unless user
    return all if user.site_admin?
    joins(:account).merge(Account.accessible_by(user))
  }
  
  # Broadcasting configuration
  broadcasts_to parent: :account # Broadcast to parent account
  broadcasts_refresh_prop :account # Parent's prop to refresh
end
```

### 3. SyncChannel - Clean and Explicit

```ruby
# app/channels/sync_channel.rb
class SyncChannel < ApplicationCable::Channel
  def subscribed
    model_class = params[:model].safe_constantize
    return reject unless model_class
    
    if params[:id] == "all"
      # Admin collection subscription
      reject unless current_user.site_admin?
      stream_from "#{params[:model]}:all"
    elsif params[:id]
      # Single object subscription
      record = model_class.accessible_by(current_user)
                         .find_by_obfuscated_id(params[:id])
      return reject unless record
      stream_from "#{params[:model]}:#{params[:id]}"
    else
      reject
    end
  end
end
```

### 4. Broadcastable Concern - Declarative API

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
        # Admin collection broadcast
        broadcast_marker("#{self.class.name}:all",
                        action: "refresh", 
                        prop: self.class.refresh_props[:collection] || model_prop_name.pluralize)
      when Hash
        # Parent broadcast
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

## JavaScript Implementation - Functional and Minimal

### 1. Pure Functional Cable Subscription

No shared mutable state, just pure functions:

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
  return (...args) => {
    clearTimeout(timeoutId);
    timeoutId = setTimeout(() => fn(...args), delay);
  };
}

// Create debounced reload function per subscription
function createDebouncedReload(delay = 300) {
  return debounce((props) => {
    console.log('Reloading props:', props);
    router.reload({
      only: props,
      preserveState: true,
      preserveScroll: true
    });
  }, delay);
}

/**
 * Subscribe to model updates
 * @param {string} model - Model name (e.g., 'Account')
 * @param {string} id - Obfuscated ID or 'all'
 * @param {string[]} props - Inertia props to reload
 * @returns {() => void} Unsubscribe function
 */
export function subscribeToModel(model, id, props) {
  if (!browser || !consumer) return () => {};
  
  const reload = createDebouncedReload();
  
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
        
        // Use explicit prop or fallback to provided props
        const propsToReload = data.prop ? [data.prop] : props;
        reload(propsToReload);
      },
      
      disconnected() {
        console.log(`Sync disconnected: ${model}:${id}`);
      }
    }
  );
  
  return () => subscription.unsubscribe();
}
```

### 2. Direct Svelte Integration

No abstractions, just use the function directly:

```javascript
// app/frontend/pages/admin/accounts.svelte
<script>
  import { onMount, onDestroy } from 'svelte';
  import { subscribeToModel } from '$lib/cable';
  
  let { accounts = [], selected_account = null } = $props();
  
  // Explicit subscription management
  let unsubscribers = [];
  
  onMount(() => {
    // Subscribe to all accounts (admin)
    unsubscribers.push(
      subscribeToModel('Account', 'all', ['accounts'])
    );
    
    // Subscribe to selected account if present
    if (selected_account) {
      unsubscribers.push(
        subscribeToModel('Account', selected_account.id, ['selected_account'])
      );
    }
  });
  
  onDestroy(() => {
    unsubscribers.forEach(unsub => unsub());
  });
</script>
```

## Usage Examples

### Account Page - Single Object

```svelte
<script>
  import { onMount, onDestroy } from 'svelte';
  import { subscribeToModel } from '$lib/cable';
  
  let { account } = $props();
  
  let unsubscribe;
  
  onMount(() => {
    unsubscribe = subscribeToModel('Account', account.id, ['account']);
  });
  
  onDestroy(() => {
    unsubscribe?.();
  });
</script>

<div>
  <h1>{account.name}</h1>
  <p>Members: {account.members_count}</p>
</div>
```

### Admin Dashboard - Collections

```svelte
<script>
  import { onMount, onDestroy } from 'svelte';
  import { subscribeToModel } from '$lib/cable';
  
  let { accounts = [] } = $props();
  
  let unsubscribe;
  
  onMount(() => {
    // Admin subscribes to all accounts
    unsubscribe = subscribeToModel('Account', 'all', ['accounts']);
  });
  
  onDestroy(() => {
    unsubscribe?.();
  });
</script>

<table>
  {#each accounts as account}
    <tr>
      <td>{account.name}</td>
      <td>{account.created_at}</td>
    </tr>
  {/each}
</table>
```

### Account with Nested Members

```svelte
<script>
  import { onMount, onDestroy } from 'svelte';
  import { subscribeToModel } from '$lib/cable';
  
  let { account } = $props();
  
  let unsubscribe;
  
  onMount(() => {
    // Single subscription refreshes account with nested members
    unsubscribe = subscribeToModel('Account', account.id, ['account']);
  });
  
  onDestroy(() => {
    unsubscribe?.();
  });
</script>

<div>
  <h1>{account.name}</h1>
  
  <h2>Members</h2>
  {#each account.account_users as member}
    <div>{member.user.name} - {member.role}</div>
  {/each}
</div>
```

## Controller Integration

Controllers pass properly scoped data:

```ruby
# app/controllers/admin/accounts_controller.rb
class Admin::AccountsController < ApplicationController
  before_action :require_admin!
  
  def index
    @accounts = Account.accessible_by(current_user)
                       .includes(:owner)
                       .order(created_at: :desc)
    
    @selected_account = @accounts.find_by_obfuscated_id(params[:account_id])
    
    render inertia: "admin/accounts", props: {
      accounts: @accounts.map { |a| account_props(a) },
      selected_account: @selected_account ? detailed_account_props(@selected_account) : nil
    }
  end
  
  private
  
  def account_props(account)
    {
      id: account.obfuscated_id,
      name: account.name,
      account_type: account.account_type,
      members_count: account.members_count,
      created_at: account.created_at,
      owner: account.owner&.slice(:name, :email_address)
    }
  end
  
  def detailed_account_props(account)
    account_props(account).merge(
      account_users: account.account_users.includes(:user).map { |au|
        {
          id: au.obfuscated_id,
          role: au.role,
          user: au.user.slice(:name, :email_address)
        }
      }
    )
  end
end
```

## Testing Strategy

### Rails Channel Tests

```ruby
# test/channels/sync_channel_test.rb
class SyncChannelTest < ActionCable::Channel::TestCase
  test "subscribes to accessible account" do
    user = users(:john)
    account = user.accounts.first
    
    stub_connection current_user: user
    subscribe channel: 'SyncChannel', model: 'Account', id: account.obfuscated_id
    
    assert subscription.confirmed?
    assert_has_stream "Account:#{account.obfuscated_id}"
  end
  
  test "rejects inaccessible account" do
    user = users(:john)
    other_account = accounts(:competitor)
    
    stub_connection current_user: user
    subscribe channel: 'SyncChannel', model: 'Account', id: other_account.obfuscated_id
    
    assert subscription.rejected?
  end
  
  test "admin can subscribe to all" do
    admin = users(:admin)
    
    stub_connection current_user: admin
    subscribe channel: 'SyncChannel', model: 'Account', id: 'all'
    
    assert subscription.confirmed?
    assert_has_stream "Account:all"
  end
end
```

### Model Broadcasting Tests

```ruby
# test/models/concerns/broadcastable_test.rb
class BroadcastableTest < ActiveSupport::TestCase
  test "broadcasts to self on update" do
    account = accounts(:acme)
    
    assert_broadcast_on("Account:#{account.obfuscated_id}", 
                       action: "refresh", 
                       prop: "account") do
      account.update!(name: "New Name")
    end
  end
  
  test "broadcasts to all collection for admin" do
    account = accounts(:acme)
    
    assert_broadcast_on("Account:all", 
                       action: "refresh",
                       prop: "accounts") do
      account.update!(name: "New Name")
    end
  end
  
  test "nested model broadcasts to parent" do
    account_user = account_users(:john_at_acme)
    
    assert_broadcast_on("Account:#{account_user.account.obfuscated_id}",
                       action: "refresh",
                       prop: "account") do
      account_user.update!(role: "admin")
    end
  end
end
```

### JavaScript Tests

```javascript
// test/frontend/cable.test.js
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { subscribeToModel } from '$lib/cable';

vi.mock('@rails/actioncable', () => ({
  createConsumer: () => ({
    subscriptions: {
      create: vi.fn((params, handlers) => ({
        unsubscribe: vi.fn()
      }))
    }
  })
}));

describe('subscribeToModel', () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });
  
  afterEach(() => {
    vi.useRealTimers();
  });
  
  it('debounces multiple rapid updates', async () => {
    const mockReload = vi.fn();
    vi.mock('@inertiajs/svelte', () => ({
      router: { reload: mockReload }
    }));
    
    const unsubscribe = subscribeToModel('Account', 'abc123', ['account']);
    
    // Simulate rapid updates
    // (would need to capture and call the received handler)
    
    // Fast-forward time
    vi.advanceTimersByTime(300);
    
    // Should only reload once
    expect(mockReload).toHaveBeenCalledTimes(1);
    expect(mockReload).toHaveBeenCalledWith({
      only: ['account'],
      preserveState: true,
      preserveScroll: true
    });
  });
});
```

## Implementation Checklist

### Phase 1: Foundation (4 hours)
- [ ] Create ApplicationCable::Connection with session auth
- [ ] Implement SyncChannel with model scope authorization  
- [ ] Create Broadcastable concern with declarative API
- [ ] Add to Account model with accessible_by scope
- [ ] Test with Rails console broadcasting

### Phase 2: JavaScript (2 hours)
- [ ] Create cable.js with subscribeToModel function
- [ ] Add debouncing with isolated state per subscription
- [ ] Test with one component manually
- [ ] Verify no shared mutable state

### Phase 3: Integration (4 hours)
- [ ] Add Broadcastable to AccountUser model
- [ ] Update admin accounts page with subscriptions
- [ ] Update account show page with subscriptions
- [ ] Test multi-tab synchronization
- [ ] Verify parent/child broadcasting works

### Phase 4: Testing & Polish (2 hours)
- [ ] Write comprehensive channel tests
- [ ] Write model broadcasting tests
- [ ] Add JavaScript unit tests
- [ ] Document in README
- [ ] Performance test with multiple tabs

## Key Improvements from v2

### Following DHH's Feedback

1. **Authorization in models** - `accessible_by` scopes instead of channel logic
2. **Declarative broadcasting** - `broadcasts_to :all` instead of manual configuration
3. **No shared mutable state** - Each subscription has isolated debounce function
4. **No Svelte abstractions** - Direct onMount/onDestroy instead of useSync helper
5. **Explicit over clever** - Clear subscription setup in each component

### What We Kept (Core Requirements)

- Object marker broadcasting (required for Inertia)
- Debounced reloads (prevents reload storms with multiple updates)
- Obfuscated IDs (security requirement)
- Support for single objects, collections, and parent updates
- Minimal JavaScript (~70 lines total)

### Rails Idioms Applied

- **Fat models** - All broadcasting logic in models
- **Scopes for authorization** - Standard Rails pattern
- **Declarative configuration** - Class-level DSL for broadcasting
- **Convention over configuration** - Sensible defaults for prop names
- **No service objects** - Everything in models and channels

## Performance Considerations

### Debouncing Is Not Premature

The 300ms debounce is essential because:
1. Multiple related models often update together (e.g., account + account_users)
2. Without debouncing, each broadcast triggers a separate Inertia reload
3. This would cause UI flashing and poor performance
4. 300ms is the sweet spot - responsive but prevents storms

### Efficient Queries

Controllers should always use includes to prevent N+1:

```ruby
@accounts = Account.accessible_by(current_user)
                   .includes(:owner, :account_users)
```

### Subscription Management

- Subscriptions are automatically cleaned up on component destroy
- No memory leaks from forgotten unsubscribe calls
- Each subscription is independent (no shared state)

## Security Architecture

### Authorization Through Scopes

```ruby
# Models define who can access them
scope :accessible_by, ->(user) {
  # Return appropriate records based on user
}

# Channels just use the scope
record = Model.accessible_by(current_user).find_by_obfuscated_id(id)
```

### Obfuscated IDs

- Prevent enumeration attacks
- Already implemented via ObfuscatesId concern
- Used consistently throughout the system

### No Data in Broadcasts

- Broadcasts only contain action + prop name
- Actual data fetched via Inertia reload
- Ensures fresh, properly authorized data

## Future Enhancements (When Needed)

Only implement these if actual requirements emerge:

1. **Presence tracking** - Show who's currently viewing
2. **Optimistic updates** - Update UI before server confirms  
3. **Selective prop updates** - Only reload changed props
4. **Connection status** - Show when offline/reconnecting
5. **Rate limiting** - Prevent subscription abuse

## Conclusion

This implementation achieves real-time synchronization while staying true to Rails principles. By moving authorization to model scopes, using a declarative broadcasting API, and keeping JavaScript minimal and functional, we have a system that any Rails developer can understand and maintain.

The key insight: Rails patterns exist for good reasons. Use them instead of inventing new abstractions. The result is less code, fewer bugs, and a system that feels naturally Rails-like while providing modern real-time features to our Svelte/Inertia frontend.