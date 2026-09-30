# Real-time Synchronization - Usage Guide

This guide explains how to use the real-time synchronization system to automatically update Svelte components when Rails models change.

## Quick Start

### 1. Add Broadcasting to Your Rails Model

```ruby
class Account < ApplicationRecord
  include SyncAuthorizable  # For authorization
  include Broadcastable      # For broadcasting
  
  # Broadcast to admin collection (for index pages)
  broadcasts_to :all
end
```

### 2. Subscribe in Your Svelte Component

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { accounts = [] } = $props();
  
  // When any account changes, reload the 'accounts' prop
  useSync({
    'Account:all': 'accounts'
  });
</script>
```

That's it! When any Account is created, updated, or deleted, your component will automatically refresh the `accounts` prop.

## Broadcasting Patterns

### Pattern 1: Admin Collections

For admin index pages showing all records:

```ruby
class User < ApplicationRecord
  include SyncAuthorizable
  include Broadcastable
  
  broadcasts_to :all  # Only site admins can subscribe
end
```

```svelte
// In admin/users.svelte
useSync({
  'User:all': 'users'  // Reload 'users' prop when any user changes
});
```

### Pattern 2: Parent-Child Relationships

When a child record should update its parent:

```ruby
class AccountUser < ApplicationRecord
  include Broadcastable
  belongs_to :account
  
  # When this AccountUser changes, broadcast to its account
  broadcasts_to :account
end
```

```svelte
// In account show page
let { account, members } = $props();

useSync({
  [`Account:${account.id}`]: ['account', 'members']  // Reload both props
});
```

### Pattern 3: Many-to-Many Broadcasting

When a record should broadcast to multiple associated records:

```ruby
class User < ApplicationRecord
  include Broadcastable
  has_many :account_users
  has_many :accounts, through: :account_users
  
  # When user changes, broadcast to ALL their accounts
  broadcasts_to :accounts  # Rails detects this is a collection
end
```

This automatically broadcasts to each account the user belongs to.

## Dynamic Subscriptions

When subscriptions need to change based on reactive state:

```svelte
<script>
  import { createDynamicSync } from '$lib/use-sync';
  
  let { accounts = [], selected_account = null } = $props();
  
  const updateSync = createDynamicSync();
  
  // Update subscriptions when selected_account changes
  $effect(() => {
    const subs = { 'Account:all': 'accounts' };
    
    if (selected_account) {
      subs[`Account:${selected_account.id}`] = 'selected_account';
    }
    
    updateSync(subs);
  });
</script>
```

## Subscription Mapping

The subscription object maps channels to props:

```javascript
useSync({
  'Model:id': 'prop_name',                    // Single prop
  'Model:id': ['prop1', 'prop2'],            // Multiple props
  'Model:all': 'collection_prop',            // Collection
  [`Model:${obj.id}`]: 'dynamic_prop'        // Dynamic ID
});
```

## Authorization

### Account-Scoped Models

Models with an `account` association are accessible by all users in that account:

```ruby
class Project < ApplicationRecord
  include SyncAuthorizable
  include Broadcastable
  
  belongs_to :account  # This enables account-based access
  
  broadcasts_to :all   # For account's project index
end
```

### Admin-Only Models

Models without an `account` association are admin-only:

```ruby
class SystemSetting < ApplicationRecord
  include SyncAuthorizable
  include Broadcastable
  
  # No account association = admin only
  broadcasts_to :all
end
```

## Common Patterns

### 1. Index Page with Selected Item

```svelte
<script>
  import { createDynamicSync } from '$lib/use-sync';
  
  let { items = [], selected_item = null } = $props();
  
  const updateSync = createDynamicSync();
  
  $effect(() => {
    const subs = { 'Item:all': 'items' };
    if (selected_item) {
      subs[`Item:${selected_item.id}`] = 'selected_item';
    }
    updateSync(subs);
  });
</script>
```

### 2. Detail Page with Related Data

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { account, members, projects } = $props();
  
  // One channel updates multiple related props
  useSync({
    [`Account:${account.id}`]: ['account', 'members', 'projects']
  });
</script>
```

### 3. Dashboard with Multiple Models

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  
  let { current_user, notifications, recent_activity } = $props();
  
  useSync({
    [`User:${current_user.id}`]: 'current_user',
    'Notification:all': 'notifications',
    'Activity:recent': 'recent_activity'
  });
</script>
```

## Best Practices

1. **Use `:all` sparingly** - It's mainly for admin pages
2. **Group related props** - One subscription can reload multiple props
3. **Use dynamic subscriptions** - When selections change
4. **Include SyncAuthorizable** - For proper access control
5. **Test authorization** - Ensure users can't subscribe to unauthorized data

## Debugging

If subscriptions aren't working:

1. Check browser console for WebSocket connection
2. Verify the model includes `Broadcastable`
3. Check authorization with `SyncAuthorizable`
4. Ensure prop names match controller's render
5. Look for ActionCable errors in Rails logs