# Real-time Synchronization for Svelte/Inertia - Simplified Implementation

## Executive Summary

This revised specification implements real-time synchronization for Rails 8 + Svelte 5 + Inertia.js applications, addressing DHH's feedback about unnecessary complexity while maintaining all functional requirements. The system broadcasts minimal object markers when data changes, triggering debounced Inertia partial reloads.

**Key simplifications from v1:**
- No SyncRegistry abstraction - use ActionCable directly
- Simpler channel patterns following Rails conventions
- Minimal JavaScript with clear, explicit code
- Model-centric broadcasting logic
- Built-in debouncing (not premature optimization - required to prevent reload storms)

## Core Architecture

### Data Flow

```
Model Update → Broadcast Marker → ActionCable → Svelte Component → Debounced Inertia Reload
```

### Design Principles

1. **Rails conventions first** - Use Rails patterns wherever possible
2. **Explicit over clever** - Clear, readable code beats abstractions
3. **Model-centric** - Broadcasting logic lives in models
4. **Minimal JavaScript** - Let Rails do the heavy lifting
5. **Security through simplicity** - Use Rails associations for authorization

## Rails Implementation

### 1. ActionCable Connection

Keep authentication simple and clear:

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
      # Use your existing session authentication
      if session = Session.find_by(id: cookies.signed[:session_id])
        session.user
      else
        reject_unauthorized_connection
      end
    end
  end
end
```

### 2. SyncChannel - Simple and Explicit

No complex patterns, just straightforward Rails code:

```ruby
# app/channels/sync_channel.rb
class SyncChannel < ApplicationCable::Channel
  def subscribed
    # Subscribe to a specific model and ID
    if params[:model] && params[:id]
      if authorized_for?(params[:model], params[:id])
        stream_from "#{params[:model]}:#{params[:id]}"
      else
        reject
      end
    # Subscribe to a collection (admin only)
    elsif params[:model] && params[:all]
      if current_user.site_admin?
        stream_from "#{params[:model]}:all"
      else
        reject
      end
    else
      reject
    end
  end

  private

  def authorized_for?(model_name, obfuscated_id)
    return false unless current_user
    
    # Simple, explicit authorization using Rails associations
    case model_name
    when "Account"
      current_user.accounts.find_by_obfuscated_id(obfuscated_id).present?
    when "AccountUser"
      account_user = AccountUser.find_by_obfuscated_id(obfuscated_id)
      account_user && current_user.accounts.include?(account_user.account)
    else
      # Add other models as needed
      false
    end
  end
end
```

### 3. Broadcastable Concern - Keep It Simple

```ruby
# app/models/concerns/broadcastable.rb
module Broadcastable
  extend ActiveSupport::Concern

  included do
    after_commit :broadcast_update, on: [:create, :update]
    after_commit :broadcast_destroy, on: :destroy
  end

  private

  def broadcast_update
    # Broadcast to the object itself
    ActionCable.server.broadcast(
      "#{self.class.name}:#{obfuscated_id}",
      { action: "update", prop: inertia_prop_name }
    )
    
    # Broadcast to :all collection if this is a root model
    if self.class.broadcast_to_all?
      ActionCable.server.broadcast(
        "#{self.class.name}:all",
        { action: "update", prop: inertia_prop_name.pluralize }
      )
    end
    
    # Broadcast to parent if this is a nested model
    if respond_to?(:broadcast_parent) && broadcast_parent
      ActionCable.server.broadcast(
        "#{broadcast_parent.class.name}:#{broadcast_parent.obfuscated_id}",
        { action: "update", prop: parent_prop_name }
      )
    end
  end

  def broadcast_destroy
    # Similar to update but with destroy action
    ActionCable.server.broadcast(
      "#{self.class.name}:#{obfuscated_id}",
      { action: "destroy", prop: inertia_prop_name }
    )
    
    if self.class.broadcast_to_all?
      ActionCable.server.broadcast(
        "#{self.class.name}:all",
        { action: "destroy", prop: inertia_prop_name.pluralize }
      )
    end
    
    if respond_to?(:broadcast_parent) && broadcast_parent
      ActionCable.server.broadcast(
        "#{broadcast_parent.class.name}:#{broadcast_parent.obfuscated_id}",
        { action: "destroy", prop: parent_prop_name }
      )
    end
  end
  
  def inertia_prop_name
    self.class.name.underscore
  end
  
  def parent_prop_name
    # Override in models if the parent prop name differs
    broadcast_parent.class.name.underscore
  end

  module ClassMethods
    def broadcast_to_all?
      # Override in models that should broadcast to :all
      false
    end
  end
end
```

### 4. Model Integration

```ruby
# app/models/account.rb
class Account < ApplicationRecord
  include ObfuscatesId
  include Broadcastable
  
  def self.broadcast_to_all?
    true # Accounts broadcast to :all for admin dashboards
  end
end

# app/models/account_user.rb
class AccountUser < ApplicationRecord
  include ObfuscatesId
  include Broadcastable
  
  belongs_to :account
  
  # Define parent for broadcasting
  def broadcast_parent
    account
  end
  
  def parent_prop_name
    "account" # The prop that contains account data with nested users
  end
end
```

## JavaScript Implementation - Minimal and Clear

### 1. Simple Cable Subscription Helper

No abstractions, just a straightforward helper:

```javascript
// app/frontend/lib/sync.js
import { createConsumer } from '@rails/actioncable';
import { router } from '@inertiajs/svelte';
import { browser } from '$app/environment';

// Simple debounce utility
function debounce(func, wait) {
  let timeout;
  return function executedFunction(...args) {
    const later = () => {
      clearTimeout(timeout);
      func(...args);
    };
    clearTimeout(timeout);
    timeout = setTimeout(later, wait);
  };
}

// Create consumer once
let consumer;
if (browser) {
  consumer = createConsumer();
}

// Track active subscriptions for cleanup
const activeSubscriptions = new Map();

// Debounced reload function (300ms is not premature - prevents reload storms)
const reloadProps = debounce((props) => {
  const uniqueProps = [...new Set(props)];
  console.log('Reloading props:', uniqueProps);
  
  router.reload({
    only: uniqueProps,
    preserveState: true,
    preserveScroll: true
  });
}, 300);

// Pending props to reload
let pendingProps = [];

/**
 * Subscribe to a model for real-time updates
 * @param {string} model - The model name (e.g., 'Account')
 * @param {string} id - The obfuscated ID or 'all'
 * @param {string} prop - The Inertia prop to reload
 * @returns {function} Unsubscribe function
 */
export function subscribe(model, id, prop) {
  if (!browser || !consumer) return () => {};

  const key = `${model}:${id}:${prop}`;
  
  // Return existing subscription if already subscribed
  if (activeSubscriptions.has(key)) {
    return activeSubscriptions.get(key).unsubscribe;
  }

  const params = { channel: 'SyncChannel', model };
  if (id === 'all') {
    params.all = true;
  } else {
    params.id = id;
  }

  const subscription = consumer.subscriptions.create(params, {
    connected() {
      console.log(`Connected to ${model}:${id}`);
    },
    
    received(data) {
      console.log(`Received update for ${model}:${id}`, data);
      
      // Add to pending props and trigger debounced reload
      pendingProps.push(data.prop || prop);
      reloadProps(pendingProps);
    },
    
    disconnected() {
      console.log(`Disconnected from ${model}:${id}`);
    }
  });

  const unsubscribe = () => {
    subscription.unsubscribe();
    activeSubscriptions.delete(key);
  };

  activeSubscriptions.set(key, { subscription, unsubscribe });
  
  return unsubscribe;
}

/**
 * Clear all pending reloads (useful for testing)
 */
export function clearPendingReloads() {
  pendingProps = [];
}
```

### 2. Svelte Integration

Simple, explicit component usage:

```javascript
// app/frontend/lib/use-sync.js
import { onMount, onDestroy } from 'svelte';
import { subscribe } from './sync';

/**
 * Svelte helper for subscribing to model updates
 * 
 * @param {Object[]} subscriptions - Array of subscription configs
 * @example
 * useSync([
 *   { model: 'Account', id: account.id, prop: 'account' },
 *   { model: 'Account', id: 'all', prop: 'accounts' }
 * ]);
 */
export function useSync(subscriptions) {
  const unsubscribers = [];

  onMount(() => {
    subscriptions.forEach(({ model, id, prop }) => {
      if (model && id && prop) {
        const unsubscribe = subscribe(model, id, prop);
        unsubscribers.push(unsubscribe);
      }
    });
  });

  onDestroy(() => {
    unsubscribers.forEach(unsubscribe => unsubscribe());
  });
}
```

## Usage Examples

### Single Object Synchronization

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { account } = $props();
  
  // Simple, explicit subscription
  useSync([
    { model: 'Account', id: account.id, prop: 'account' }
  ]);
</script>

<div>
  <h1>{account.name}</h1>
  <p>Updated: {account.updated_at}</p>
</div>
```

### Collection Synchronization (Admin)

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { accounts = [] } = $props();
  
  // Admin subscribes to all accounts
  useSync([
    { model: 'Account', id: 'all', prop: 'accounts' }
  ]);
</script>

<ul>
  {#each accounts as account}
    <li>{account.name}</li>
  {/each}
</ul>
```

### Multiple Subscriptions

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { accounts = [], selected_account = null } = $props();
  
  // Build subscriptions array
  const subscriptions = [
    { model: 'Account', id: 'all', prop: 'accounts' }
  ];
  
  if (selected_account) {
    subscriptions.push({
      model: 'Account',
      id: selected_account.id,
      prop: 'selected_account'
    });
  }
  
  useSync(subscriptions);
</script>
```

## Authorization and Security

### Simple, Rails-Based Authorization

1. **Use Rails associations** - Let Rails handle authorization naturally
2. **Obfuscated IDs** - Prevent enumeration attacks
3. **Session-based auth** - Use existing Rails session authentication
4. **Admin checks** - Simple `user.site_admin?` for collection access

### No Complex Patterns

- No row-level database security
- No service objects for authorization
- No complex permission systems
- Just Rails associations and RecordNotFound

## Testing Strategy

### Rails Tests

```ruby
# test/channels/sync_channel_test.rb
class SyncChannelTest < ActionCable::Channel::TestCase
  test "subscribes to owned account" do
    user = users(:one)
    account = user.accounts.first
    
    stub_connection current_user: user
    subscribe channel: 'SyncChannel', model: 'Account', id: account.obfuscated_id
    
    assert subscription.confirmed?
    assert_has_stream "Account:#{account.obfuscated_id}"
  end
  
  test "rejects subscription to unowned account" do
    user = users(:one)
    other_account = accounts(:two) # Not owned by user
    
    stub_connection current_user: user
    subscribe channel: 'SyncChannel', model: 'Account', id: other_account.obfuscated_id
    
    assert subscription.rejected?
  end
end

# test/models/concerns/broadcastable_test.rb
class BroadcastableTest < ActiveSupport::TestCase
  test "broadcasts on update" do
    account = accounts(:one)
    
    assert_broadcast_on("Account:#{account.obfuscated_id}", action: "update") do
      account.update!(name: "New Name")
    end
  end
end
```

### JavaScript Tests

```javascript
// app/frontend/lib/sync.test.js
import { describe, it, expect, vi } from 'vitest';
import { subscribe } from './sync';

describe('sync', () => {
  it('debounces multiple updates', async () => {
    const mockReload = vi.fn();
    vi.mock('@inertiajs/svelte', () => ({
      router: { reload: mockReload }
    }));
    
    // Trigger multiple updates quickly
    // ... test implementation
    
    // Should only reload once after debounce
    await vi.advanceTimersByTime(300);
    expect(mockReload).toHaveBeenCalledTimes(1);
  });
});
```

## Implementation Checklist

### Phase 1: Foundation (Day 1-2)
- [ ] Create ApplicationCable::Connection
- [ ] Create simple SyncChannel
- [ ] Add Broadcastable concern
- [ ] Test with one model (Account)

### Phase 2: JavaScript (Day 3-4)
- [ ] Create sync.js with subscribe function
- [ ] Add debouncing logic
- [ ] Create use-sync.js Svelte helper
- [ ] Test with one component

### Phase 3: Integration (Day 5)
- [ ] Add Broadcastable to all models
- [ ] Update components to use sync
- [ ] Test multi-tab synchronization
- [ ] Add error handling

### Phase 4: Polish (Day 6-7)
- [ ] Add logging for debugging
- [ ] Write comprehensive tests
- [ ] Document usage patterns
- [ ] Performance testing

## Key Differences from v1

### What We Kept (Requirements)
- Object marker broadcasting (not Turbo Streams)
- Debounced reloads (prevents reload storms)
- Subscription mapping to Inertia props
- Support for objects, collections, and admin "all"
- Obfuscated IDs for security

### What We Simplified (Following DHH Feedback)
- **No SyncRegistry class** - Use ActionCable directly
- **Simpler channel patterns** - Just model:id, not complex paths
- **Explicit authorization** - Clear Rails association checks
- **Minimal JavaScript** - Under 100 lines total
- **Model-centric broadcasting** - Logic lives in models
- **No premature abstractions** - Add complexity only when needed

### What We Clarified
- Debouncing is NOT premature optimization - it's required
- We can't use broadcast_refresh_to - we're using Inertia, not Turbo
- Obfuscated IDs are a security requirement
- The subscription mapping is necessary for Inertia partial reloads

## Future Considerations

Only add these if/when actually needed:

1. **Presence tracking** - Show who's viewing/editing
2. **Optimistic updates** - Update UI before server confirmation
3. **Conflict resolution** - Handle simultaneous edits
4. **Rate limiting** - Prevent subscription abuse
5. **Analytics** - Track usage patterns

## Conclusion

This simplified implementation maintains all functional requirements while following Rails conventions more closely. The code is explicit rather than clever, making it easier to understand and maintain. We've eliminated unnecessary abstractions while keeping the essential functionality that makes this system work with Svelte + Inertia.js.

The key insight from the DHH feedback: keep it simple, use Rails patterns where possible, and only add complexity when absolutely necessary. This implementation does exactly that while still meeting our unique requirements for Svelte/Inertia synchronization.