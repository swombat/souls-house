# Svelte/Rails Synchronization System - Implementation Specification

## Executive Summary

This specification details the implementation of a real-time synchronization system for Rails 8 + Svelte 5 + Inertia.js applications. The system uses ActionCable to broadcast minimal object/collection markers when data changes, triggering Inertia partial page reloads on subscribed clients. This approach minimizes network traffic while providing real-time updates with minimal boilerplate.

Key features:
- Object-based subscriptions using obfuscated IDs
- Debounced partial page reloads (300ms)
- Automatic cleanup on navigation
- Secure, authenticated subscriptions
- Zero serialization overhead on the Rails side

## 1. System Architecture Overview

### High-Level Data Flow

```
┌─────────────┐      ┌─────────────┐      ┌─────────────┐
│   Model     │      │  ActionCable │      │   Svelte    │
│   Update    ├─────►│  Broadcast   ├─────►│   Client    │
└─────────────┘      └─────────────┘      └──────┬──────┘
                                                  │
                                                  ▼
                                          ┌─────────────┐
                                          │  Debounced  │
                                          │   Inertia   │
                                          │   Reload    │
                                          └─────────────┘
```

### Component Responsibilities

1. **Rails Model Concern (Broadcastable)**
   - Broadcasts object/collection identifiers on create/update/destroy
   - Uses obfuscated IDs for security
   - No serialization required

2. **ActionCable Channel (SyncChannel)**
   - Authenticates subscriptions
   - Validates access to requested objects
   - Streams identifiers to authorized clients

3. **JavaScript SyncRegistry**
   - Manages cable subscriptions
   - Maps identifiers to Inertia props
   - Debounces and batches reload requests
   - Handles cleanup on unmount

4. **Svelte Integration Helper**
   - Provides minimal API for components
   - Auto-subscribes based on props
   - Manages lifecycle hooks

### Security Considerations

- All subscriptions require authenticated users (via session cookie)
- Object access verified through Rails associations
- Admin-only collections restricted by user.site_admin check
- Obfuscated IDs prevent enumeration attacks
- No sensitive data transmitted via cable (only identifiers)

## 2. Rails Implementation Details

### 2.1 ActionCable Channel Setup

Create `app/channels/application_cable/connection.rb`:

```ruby
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      session_id = cookies.signed[:session_id]
      return reject_unauthorized_connection unless session_id
      
      session = Session.find_by(id: session_id)
      return reject_unauthorized_connection unless session
      
      session.user
    end
  end
end
```

Create `app/channels/sync_channel.rb`:

```ruby
class SyncChannel < ApplicationCable::Channel
  def subscribed
    @subscriptions = []
  end

  def unsubscribed
    @subscriptions.each { |sub| stop_stream_from(sub) }
  end

  def subscribe_to(data)
    identifier = data["identifier"]
    
    # Validate and authorize the subscription
    if authorized_for?(identifier)
      stream_from identifier
      @subscriptions << identifier
      
      # Acknowledge successful subscription
      transmit(type: "subscribed", identifier: identifier)
    else
      # Reject unauthorized subscription
      transmit(type: "error", identifier: identifier, error: "Unauthorized")
    end
  end

  def unsubscribe_from(data)
    identifier = data["identifier"]
    stop_stream_from identifier
    @subscriptions.delete(identifier)
  end

  private

  def authorized_for?(identifier)
    return false unless current_user

    case identifier
    when /^(\w+):all$/
      # Collection of all objects - admin only
      model_class = $1.constantize rescue nil
      return false unless model_class
      current_user.site_admin
      
    when /^(\w+):([^\/]+)$/
      # Single object
      model_class, obfuscated_id = $1.constantize, $2 rescue nil
      return false unless model_class
      
      # Use Rails associations for authorization
      if model_class == Account
        current_user.accounts.find_by_obfuscated_id(obfuscated_id).present?
      else
        # Add other model authorization patterns as needed
        false
      end
      
    when /^(\w+):([^\/]+)\/(\w+)$/
      # Nested collection
      model_class, obfuscated_id, collection = $1.constantize, $2, $3 rescue nil
      return false unless model_class
      
      # Verify access to parent object
      if model_class == Account
        account = current_user.accounts.find_by_obfuscated_id(obfuscated_id)
        account.present? && account.respond_to?(collection)
      else
        false
      end
    else
      false
    end
  rescue StandardError => e
    Rails.logger.error "SyncChannel authorization error: #{e.message}"
    false
  end
end
```

### 2.2 Model Concern for Broadcasting

Create `app/models/concerns/broadcastable.rb`:

```ruby
module Broadcastable
  extend ActiveSupport::Concern

  included do
    after_commit :broadcast_create, on: :create
    after_commit :broadcast_update, on: :update  
    after_commit :broadcast_destroy, on: :destroy
    
    class_attribute :broadcast_collections, default: []
    class_attribute :broadcast_associations, default: []
  end

  class_methods do
    # Define which collections this model broadcasts to
    def broadcasts_to(*collections)
      self.broadcast_collections = collections
    end
    
    # Define which associations trigger broadcasts
    def broadcasts_on_change_of(*associations)
      self.broadcast_associations = associations
    end
  end

  private

  def broadcast_create
    broadcast_identifiers(:create)
  end

  def broadcast_update
    broadcast_identifiers(:update)
  end

  def broadcast_destroy
    broadcast_identifiers(:destroy)
  end

  def broadcast_identifiers(action)
    identifiers = []
    
    # Broadcast the object itself
    identifiers << "#{self.class.name}:#{obfuscated_id}"
    
    # Broadcast to :all collection if configured
    if broadcast_collections.include?(:all)
      identifiers << "#{self.class.name}:all"
    end
    
    # Broadcast parent associations
    broadcast_associations.each do |association|
      if parent = send(association)
        parent_identifier = "#{parent.class.name}:#{parent.obfuscated_id}"
        
        # For nested collections
        collection_name = self.class.name.underscore.pluralize
        identifiers << "#{parent_identifier}/#{collection_name}"
      end
    end
    
    # Broadcast all unique identifiers
    identifiers.uniq.each do |identifier|
      ActionCable.server.broadcast("sync", {
        identifier: identifier,
        action: action,
        timestamp: Time.current.to_i
      })
    end
  end
end
```

### 2.3 Model Integration

Update models to use the Broadcastable concern:

```ruby
class Account < ApplicationRecord
  include ObfuscatesId
  include Broadcastable
  
  # Broadcast to the :all collection for admin monitoring
  broadcasts_to :all
  
  # ... existing code ...
end

class AccountUser < ApplicationRecord
  include ObfuscatesId
  include Broadcastable
  
  # Broadcast changes to parent account's collection
  broadcasts_on_change_of :account
  
  # ... existing code ...
end
```

### 2.4 Subscription Authorization Logic

The authorization follows these patterns:

1. **Single Object** (`Account:PNvAYr`):
   - User must be a member of the account
   - Uses `current_user.accounts.find_by_obfuscated_id`

2. **Nested Collection** (`Account:PNvAYr/account_users`):
   - User must have access to parent object
   - Collection must exist on parent

3. **All Objects** (`Account:all`):
   - Requires `current_user.site_admin`
   - Used for admin dashboards

## 3. JavaScript/Svelte Implementation Details

### 3.1 SyncRegistry Class Design

Create `app/frontend/lib/sync-registry.js`:

```javascript
import { router } from '@inertiajs/svelte';
import { browser } from '$app/environment';

class SyncRegistry {
  constructor() {
    this.cable = null;
    this.channel = null;
    this.subscriptions = new Map(); // identifier -> Set of prop names
    this.pendingReloads = new Set();
    this.reloadTimer = null;
    this.debounceMs = 300;
    this.isConnected = false;
    this.reconnectAttempts = 0;
    this.maxReconnectAttempts = 5;
    this.reconnectDelay = 1000; // Start with 1 second
  }

  /**
   * Initialize cable connection
   */
  async connect() {
    if (!browser || this.cable) return;

    try {
      // Dynamically import ActionCable
      const { createConsumer } = await import('@rails/actioncable');
      
      this.cable = createConsumer();
      this.channel = this.cable.subscriptions.create('SyncChannel', {
        connected: () => {
          this.isConnected = true;
          this.reconnectAttempts = 0;
          this.reconnectDelay = 1000;
          console.log('SyncChannel connected');
          
          // Re-subscribe to all active subscriptions
          this.resubscribeAll();
        },

        disconnected: () => {
          this.isConnected = false;
          console.log('SyncChannel disconnected');
          this.scheduleReconnect();
        },

        received: (data) => {
          this.handleMessage(data);
        }
      });
    } catch (error) {
      console.error('Failed to connect to SyncChannel:', error);
      this.scheduleReconnect();
    }
  }

  /**
   * Handle incoming cable messages
   */
  handleMessage(data) {
    const { identifier, action, type, error } = data;

    // Handle subscription acknowledgments
    if (type === 'subscribed') {
      console.log(`Subscribed to ${identifier}`);
      return;
    }

    if (type === 'error') {
      console.error(`Subscription error for ${identifier}:`, error);
      return;
    }

    // Handle data updates
    const props = this.subscriptions.get(identifier);
    if (props && props.size > 0) {
      console.log(`Received update for ${identifier}, action: ${action}`);
      
      // Add all affected props to pending reloads
      props.forEach(prop => this.pendingReloads.add(prop));
      
      // Debounce the reload
      this.scheduleReload();
    }
  }

  /**
   * Subscribe to object/collection updates
   */
  subscribe(identifier, propName) {
    if (!browser) return;

    // Initialize connection if needed
    if (!this.cable) {
      this.connect();
    }

    // Track subscription
    if (!this.subscriptions.has(identifier)) {
      this.subscriptions.set(identifier, new Set());
    }
    this.subscriptions.get(identifier).add(propName);

    // Send subscription request if connected
    if (this.isConnected && this.channel) {
      this.channel.perform('subscribe_to', { identifier });
    }
  }

  /**
   * Unsubscribe from updates
   */
  unsubscribe(identifier, propName) {
    const props = this.subscriptions.get(identifier);
    if (!props) return;

    props.delete(propName);
    
    // If no more props need this identifier, unsubscribe completely
    if (props.size === 0) {
      this.subscriptions.delete(identifier);
      
      if (this.isConnected && this.channel) {
        this.channel.perform('unsubscribe_from', { identifier });
      }
    }
  }

  /**
   * Clear all subscriptions for a component
   */
  clearSubscriptions(subscriptionMap) {
    Object.entries(subscriptionMap).forEach(([identifier, propName]) => {
      this.unsubscribe(identifier, propName);
    });
  }

  /**
   * Schedule a debounced reload
   */
  scheduleReload() {
    if (this.reloadTimer) {
      clearTimeout(this.reloadTimer);
    }

    this.reloadTimer = setTimeout(() => {
      this.performReload();
    }, this.debounceMs);
  }

  /**
   * Perform the actual Inertia reload
   */
  performReload() {
    if (this.pendingReloads.size === 0) return;

    const props = Array.from(this.pendingReloads);
    this.pendingReloads.clear();

    console.log('Reloading props:', props);
    
    // Perform partial reload with all affected props
    router.reload({
      only: props,
      preserveState: true,
      preserveScroll: true
    });
  }

  /**
   * Re-subscribe to all active subscriptions after reconnect
   */
  resubscribeAll() {
    if (!this.isConnected || !this.channel) return;

    this.subscriptions.forEach((props, identifier) => {
      if (props.size > 0) {
        this.channel.perform('subscribe_to', { identifier });
      }
    });
  }

  /**
   * Schedule reconnection with exponential backoff
   */
  scheduleReconnect() {
    if (this.reconnectAttempts >= this.maxReconnectAttempts) {
      console.error('Max reconnection attempts reached');
      return;
    }

    setTimeout(() => {
      this.reconnectAttempts++;
      this.reconnectDelay = Math.min(this.reconnectDelay * 2, 30000); // Max 30 seconds
      console.log(`Attempting to reconnect (attempt ${this.reconnectAttempts})...`);
      this.connect();
    }, this.reconnectDelay);
  }

  /**
   * Disconnect and cleanup
   */
  disconnect() {
    if (this.cable) {
      this.cable.disconnect();
      this.cable = null;
      this.channel = null;
    }
    
    this.subscriptions.clear();
    this.pendingReloads.clear();
    
    if (this.reloadTimer) {
      clearTimeout(this.reloadTimer);
      this.reloadTimer = null;
    }
  }
}

// Export singleton instance
export const syncRegistry = new SyncRegistry();
```

### 3.2 Svelte Integration Helper

Create `app/frontend/lib/sync-with-rails.js`:

```javascript
import { onMount, onDestroy } from 'svelte';
import { syncRegistry } from './sync-registry';

/**
 * Svelte helper for synchronizing with Rails
 * 
 * @param {Object} mappings - Object mapping identifiers to prop names
 * @example
 * syncWithRails({
 *   'Account:all': 'accounts',
 *   'Account:PNvAYr': 'selected_account',
 *   'Account:PNvAYr/account_users': 'selected_account'
 * });
 */
export function syncWithRails(mappings) {
  // Build subscription map
  const subscriptions = {};
  
  Object.entries(mappings).forEach(([identifier, propName]) => {
    // Handle dynamic identifiers (skip if contains null/undefined)
    if (identifier.includes('null') || identifier.includes('undefined')) {
      return;
    }
    
    subscriptions[identifier] = propName;
  });

  // Subscribe on mount
  onMount(() => {
    Object.entries(subscriptions).forEach(([identifier, propName]) => {
      syncRegistry.subscribe(identifier, propName);
    });
  });

  // Unsubscribe on destroy
  onDestroy(() => {
    Object.entries(subscriptions).forEach(([identifier, propName]) => {
      syncRegistry.unsubscribe(identifier, propName);
    });
  });
}

/**
 * Helper to build dynamic identifiers safely
 */
export function buildIdentifier(model, id, collection = null) {
  if (!model || !id) return null;
  
  let identifier = `${model}:${id}`;
  if (collection) {
    identifier += `/${collection}`;
  }
  
  return identifier;
}
```

### 3.3 TypeScript Interfaces

Create `app/frontend/lib/sync-registry.d.ts`:

```typescript
export interface SyncMessage {
  identifier: string;
  action: 'create' | 'update' | 'destroy';
  timestamp: number;
  type?: 'subscribed' | 'error';
  error?: string;
}

export interface SyncOptions {
  debounceMs?: number;
  maxReconnectAttempts?: number;
  reconnectDelay?: number;
}

export class SyncRegistry {
  constructor(options?: SyncOptions);
  
  connect(): Promise<void>;
  disconnect(): void;
  subscribe(identifier: string, propName: string): void;
  unsubscribe(identifier: string, propName: string): void;
  clearSubscriptions(subscriptionMap: Record<string, string>): void;
  performReload(): void;
}

export const syncRegistry: SyncRegistry;

export function syncWithRails(mappings: Record<string, string>): void;
export function buildIdentifier(
  model: string, 
  id: string | null, 
  collection?: string
): string | null;
```

## 4. Integration Points

### 4.1 ActionCable Setup

Ensure ActionCable is properly configured in the Rails application:

```javascript
// app/frontend/entrypoints/application.js
import '@rails/actioncable';
```

Add to `package.json`:
```json
{
  "dependencies": {
    "@rails/actioncable": "^7.2.0"
  }
}
```

### 4.2 Inertia.js Integration

The system integrates seamlessly with existing Inertia setup:

1. Uses `router.reload()` for partial updates
2. Preserves state and scroll position
3. Works with existing authentication
4. Compatible with Inertia's progress indicators

### 4.3 Svelte Component Lifecycle

The sync system respects Svelte's lifecycle:

1. **onMount**: Establishes subscriptions
2. **Component lifetime**: Receives updates, triggers reloads
3. **onDestroy**: Cleans up subscriptions
4. **Page transitions**: Automatic cleanup via onDestroy

## 5. Usage Examples

### 5.1 Single Object Sync

```svelte
<script>
  import { syncWithRails, buildIdentifier } from '$lib/sync-with-rails';
  
  let { account = null } = $props();
  
  // Subscribe to account updates
  if (account) {
    syncWithRails({
      [buildIdentifier('Account', account.id)]: 'account'
    });
  }
</script>

<div>
  <h1>{account.name}</h1>
  <p>Members: {account.members_count}</p>
</div>
```

### 5.2 Collection Sync

```svelte
<script>
  import { syncWithRails } from '$lib/sync-with-rails';
  
  let { accounts = [] } = $props();
  
  // Subscribe to all accounts (admin only)
  syncWithRails({
    'Account:all': 'accounts'
  });
</script>

<ul>
  {#each accounts as account}
    <li>{account.name}</li>
  {/each}
</ul>
```

### 5.3 Complex Page with Multiple Subscriptions

```svelte
<script>
  import { syncWithRails, buildIdentifier } from '$lib/sync-with-rails';
  
  let { accounts = [], selected_account = null } = $props();
  
  // Build subscription map dynamically
  const subscriptions = {
    'Account:all': 'accounts'
  };
  
  if (selected_account) {
    subscriptions[buildIdentifier('Account', selected_account.id)] = 'selected_account';
    subscriptions[buildIdentifier('Account', selected_account.id, 'account_users')] = 'selected_account';
  }
  
  syncWithRails(subscriptions);
</script>

<div class="flex">
  <aside>
    {#each accounts as account}
      <button>{account.name}</button>
    {/each}
  </aside>
  
  <main>
    {#if selected_account}
      <h1>{selected_account.name}</h1>
      <ul>
        {#each selected_account.account_users as member}
          <li>{member.user.email}</li>
        {/each}
      </ul>
    {/if}
  </main>
</div>
```

### 5.4 Admin-Only Collection Sync

Controller:
```ruby
class Admin::AccountsController < ApplicationController
  before_action :require_admin
  
  def index
    render inertia: 'admin/accounts', props: {
      accounts: Account.all.as_json(include: :owner)
    }
  end
  
  private
  
  def require_admin
    redirect_to root_path unless current_user.site_admin
  end
end
```

Component:
```svelte
<script>
  import { syncWithRails } from '$lib/sync-with-rails';
  
  let { accounts = [] } = $props();
  
  // Admin can subscribe to all accounts
  syncWithRails({
    'Account:all': 'accounts'
  });
</script>
```

## 6. Performance Considerations

### 6.1 Debouncing Strategy

- **Default**: 300ms debounce window
- **Configurable**: Can be adjusted per-component if needed
- **Batching**: Multiple updates within window are combined
- **Benefits**: Reduces server load, prevents UI flicker

### 6.2 Subscription Limits

To prevent abuse:
- Limit subscriptions per connection (e.g., 100)
- Rate limit subscription requests
- Monitor and log excessive subscriptions

Implementation in `SyncChannel`:
```ruby
MAX_SUBSCRIPTIONS = 100

def subscribe_to(data)
  if @subscriptions.size >= MAX_SUBSCRIPTIONS
    transmit(type: "error", error: "Subscription limit reached")
    return
  end
  # ... rest of method
end
```

### 6.3 Memory Management

JavaScript client:
- Automatic cleanup on component unmount
- Subscription deduplication via Map/Set
- Clear timers on disconnect

Rails server:
- Automatic cleanup on disconnect
- No object serialization overhead
- Efficient identifier broadcasting

### 6.4 Network Traffic Minimization

- Only identifiers transmitted (no payloads)
- Partial reloads fetch only changed props
- Debouncing prevents request storms
- WebSocket compression enabled by default

## 7. Testing Strategy

### 7.1 Rails Unit Tests

Test the Broadcastable concern:

```ruby
# test/models/concerns/broadcastable_test.rb
require 'test_helper'

class BroadcastableTest < ActiveSupport::TestCase
  test "broadcasts create" do
    assert_broadcast_on("sync", identifier: /Account:/) do
      Account.create!(name: "Test Account")
    end
  end
  
  test "broadcasts update" do
    account = accounts(:one)
    assert_broadcast_on("sync", identifier: "Account:#{account.obfuscated_id}") do
      account.update!(name: "Updated Name")
    end
  end
  
  test "broadcasts destroy" do
    account = accounts(:one)
    assert_broadcast_on("sync", identifier: "Account:#{account.obfuscated_id}") do
      account.destroy!
    end
  end
end
```

Test the SyncChannel:

```ruby
# test/channels/sync_channel_test.rb
require 'test_helper'

class SyncChannelTest < ActionCable::Channel::TestCase
  setup do
    @user = users(:one)
    @account = @user.accounts.first
  end
  
  test "subscribes to owned account" do
    stub_connection current_user: @user
    subscribe
    
    perform :subscribe_to, identifier: "Account:#{@account.obfuscated_id}"
    assert_has_stream "Account:#{@account.obfuscated_id}"
  end
  
  test "rejects subscription to unowned account" do
    other_account = accounts(:two)
    stub_connection current_user: @user
    subscribe
    
    perform :subscribe_to, identifier: "Account:#{other_account.obfuscated_id}"
    assert_no_streams
  end
  
  test "admin can subscribe to all" do
    @user.update!(is_site_admin: true)
    stub_connection current_user: @user
    subscribe
    
    perform :subscribe_to, identifier: "Account:all"
    assert_has_stream "Account:all"
  end
end
```

### 7.2 JavaScript Tests

Test the SyncRegistry:

```javascript
// app/frontend/lib/sync-registry.test.js
import { describe, it, expect, beforeEach, vi } from 'vitest';
import { SyncRegistry } from './sync-registry';

describe('SyncRegistry', () => {
  let registry;
  
  beforeEach(() => {
    registry = new SyncRegistry();
    vi.useFakeTimers();
  });
  
  it('debounces reloads', () => {
    const reloadSpy = vi.spyOn(registry, 'performReload');
    
    registry.pendingReloads.add('accounts');
    registry.scheduleReload();
    
    registry.pendingReloads.add('selected_account');
    registry.scheduleReload();
    
    // Should not reload immediately
    expect(reloadSpy).not.toHaveBeenCalled();
    
    // Fast-forward time
    vi.advanceTimersByTime(300);
    
    // Should reload once with both props
    expect(reloadSpy).toHaveBeenCalledOnce();
  });
  
  it('manages subscriptions correctly', () => {
    registry.subscribe('Account:123', 'account');
    registry.subscribe('Account:123', 'selected_account');
    
    expect(registry.subscriptions.get('Account:123').size).toBe(2);
    
    registry.unsubscribe('Account:123', 'account');
    expect(registry.subscriptions.get('Account:123').size).toBe(1);
    
    registry.unsubscribe('Account:123', 'selected_account');
    expect(registry.subscriptions.has('Account:123')).toBe(false);
  });
});
```

### 7.3 Integration Tests

Test full sync flow with Playwright:

```javascript
// e2e/sync.spec.js
import { test, expect } from '@playwright/test';

test('syncs account updates between tabs', async ({ browser }) => {
  // Open two tabs
  const context = await browser.newContext();
  const page1 = await context.newPage();
  const page2 = await context.newPage();
  
  // Navigate both to accounts page
  await page1.goto('/accounts');
  await page2.goto('/accounts');
  
  // Update account name in tab 1
  await page1.click('[data-test="edit-account"]');
  await page1.fill('[name="name"]', 'Updated Account');
  await page1.click('[type="submit"]');
  
  // Verify update appears in tab 2 within 1 second
  await expect(page2.locator('h1')).toContainText('Updated Account', { 
    timeout: 1000 
  });
});
```

### 7.4 Performance Testing

Monitor and test:
- Subscription setup time
- Update propagation latency
- Memory usage over time
- Reconnection behavior

```ruby
# test/performance/sync_performance_test.rb
require 'test_helper'
require 'benchmark'

class SyncPerformanceTest < ActionDispatch::IntegrationTest
  test "handles bulk updates efficiently" do
    time = Benchmark.realtime do
      100.times do
        Account.create!(name: "Test #{SecureRandom.hex}")
      end
    end
    
    assert time < 5.0, "Bulk creation took too long: #{time}s"
  end
end
```

## 8. Migration Path

### 8.1 Implementation Order

Phase 1 - Foundation (Week 1):
- [ ] Implement ApplicationCable::Connection
- [ ] Create SyncChannel with basic authentication
- [ ] Add Broadcastable concern
- [ ] Create SyncRegistry JavaScript class
- [ ] Add basic tests

Phase 2 - Integration (Week 2):
- [ ] Add syncWithRails helper
- [ ] Update one model (Account) to use Broadcastable
- [ ] Convert one page to use sync
- [ ] Add integration tests
- [ ] Monitor performance in development

Phase 3 - Rollout (Week 3):
- [ ] Add remaining models
- [ ] Convert remaining pages
- [ ] Add performance monitoring
- [ ] Deploy to staging
- [ ] Load test

Phase 4 - Production (Week 4):
- [ ] Deploy to production with feature flag
- [ ] Gradual rollout to users
- [ ] Monitor metrics
- [ ] Full rollout

### 8.2 Backward Compatibility

The system is fully backward compatible:
- Pages without sync continue to work normally
- Can be adopted incrementally per-page
- No changes to existing Inertia props
- Falls back gracefully if WebSocket fails

### 8.3 Rollout Strategy

1. **Feature Flag**: Use environment variable to enable/disable
   ```ruby
   class SyncChannel < ApplicationCable::Channel
     def subscribed
       return reject unless ENV['ENABLE_SYNC'] == 'true'
       # ...
     end
   end
   ```

2. **Gradual Adoption**: Convert pages one at a time
3. **Monitoring**: Track WebSocket connections, reload frequency
4. **Rollback Plan**: Can disable via feature flag instantly

## 9. Future Enhancements

Potential improvements after initial implementation:

1. **Optimistic Updates**: Update UI before server confirmation
2. **Conflict Resolution**: Handle concurrent edits
3. **Presence Indicators**: Show who's viewing/editing
4. **Selective Prop Updates**: Only reload changed fields
5. **Compression**: Further reduce identifier size
6. **Analytics**: Track sync usage patterns
7. **Rate Limiting**: Per-user subscription limits
8. **Caching**: Cache partial reload responses

## Appendix A: Configuration Options

Environment variables:
```bash
ENABLE_SYNC=true
SYNC_DEBOUNCE_MS=300
SYNC_MAX_SUBSCRIPTIONS=100
SYNC_RECONNECT_ATTEMPTS=5
```

Rails configuration:
```ruby
# config/application.rb
config.sync = {
  enabled: ENV.fetch('ENABLE_SYNC', 'true') == 'true',
  debounce_ms: ENV.fetch('SYNC_DEBOUNCE_MS', 300).to_i,
  max_subscriptions: ENV.fetch('SYNC_MAX_SUBSCRIPTIONS', 100).to_i
}
```

## Appendix B: Troubleshooting Guide

Common issues and solutions:

1. **Subscriptions not working**
   - Check user authentication
   - Verify ActionCable is running
   - Check browser console for errors
   - Ensure obfuscated IDs match

2. **Updates not propagating**
   - Verify Broadcastable is included
   - Check after_commit callbacks firing
   - Monitor ActionCable logs
   - Test cable connection directly

3. **Performance issues**
   - Increase debounce time
   - Reduce subscription count
   - Check N+1 queries in partial reloads
   - Monitor WebSocket connection count

4. **Memory leaks**
   - Ensure onDestroy cleanup
   - Check subscription deduplication
   - Monitor browser memory usage
   - Verify server-side cleanup