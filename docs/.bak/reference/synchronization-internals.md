# Real-time Synchronization - Internal Architecture

**NOTE: This document is for debugging broken synchronization. For normal usage, see [synchronization-usage.md](./synchronization-usage.md).**

## Architecture Overview

The synchronization system uses:
1. **ActionCable** for WebSocket connections
2. **Minimal marker broadcasts** (not full data)
3. **Inertia.js partial reloads** to fetch updated data
4. **300ms debouncing** to prevent reload storms

## Data Flow

```
Model Change → Broadcastable → ActionCable → Browser → useSync → Inertia Reload → Props Update
```

## Component Details

### 1. Rails Broadcasting (`app/models/concerns/broadcastable.rb`)

The Broadcastable concern hooks into ActiveRecord callbacks:

```ruby
after_commit :broadcast_refresh, on: [:create, :update]
after_commit :broadcast_removal, on: :destroy
```

#### Broadcast Targets

- **`:all`** - Broadcasts to `"ModelName:all"` channel
- **Symbol** - Uses Rails reflection to detect association type:
  - `belongs_to`/`has_one` → broadcasts to single record
  - `has_many`/`has_and_belongs_to_many` → broadcasts to each record

#### Channel Format

Channels follow the pattern: `"ModelName:obfuscated_id"`

Example: `"Account:abc123def"` or `"Account:all"`

#### Broadcast Payload

Minimal marker with action:
```json
{
  "action": "refresh"  // or "remove"
}
```

### 2. ActionCable Channel (`app/channels/sync_channel.rb`)

Handles subscription authorization:

```ruby
def subscribed
  # Parse model and ID from params
  if params[:id] == "all"
    # Only admins can subscribe to :all
    if current_user.site_admin
      stream_from "#{params[:model]}:all"
    else
      reject
    end
  else
    # Check model-specific authorization
    model_class.authorize_sync(params[:id], current_user)
  end
end
```

### 3. Authorization (`app/models/concerns/sync_authorizable.rb`)

Two authorization models:

1. **Account-scoped** (has `account` association):
   - Users in the account can subscribe
   
2. **Admin-only** (no `account` association):
   - Only site admins can subscribe

```ruby
def authorize_sync(id, user)
  record = obfuscated_scope.find_by_obfuscated_id(id)
  return false unless record
  
  if reflect_on_association(:account)
    # Account-scoped: check membership
    user.member_of?(record.account)
  else
    # No account: admin only
    user.site_admin
  end
end
```

### 4. WebSocket Authentication (`app/channels/application_cable/connection.rb`)

Uses session cookies for authentication:

```ruby
def find_verified_user
  if session = Session.find_by(id: cookies.signed[:session_id])
    session.user
  else
    reject_unauthorized_connection
  end
end
```

### 5. JavaScript Cable Management (`app/frontend/lib/cable.js`)

Core subscription logic:

```javascript
export function subscribeToSync(model, id, callback) {
  // Only in browser
  if (!browser) return () => {};
  
  const channel = consumer.subscriptions.create(
    {
      channel: 'SyncChannel',
      model: model,
      id: id
    },
    {
      received(data) {
        callback(data);
      }
    }
  );
  
  // Return unsubscribe function
  return () => channel.unsubscribe();
}
```

### 6. Svelte Integration (`app/frontend/lib/use-sync.js`)

Two main functions:

#### `useSync` - Static subscriptions

```javascript
export function useSync(subscriptions) {
  onMount(() => {
    const unsubscribers = [];
    
    Object.entries(subscriptions).forEach(([channel, props]) => {
      const [model, id] = channel.split(':');
      
      const unsub = subscribeToSync(model, id, (data) => {
        // Debounced Inertia reload
        handleReload(props);
      });
      
      unsubscribers.push(unsub);
    });
    
    return () => unsubscribers.forEach(unsub => unsub());
  });
}
```

#### `createDynamicSync` - Reactive subscriptions

```javascript
export function createDynamicSync() {
  let currentUnsubscribers = [];
  
  onDestroy(() => {
    currentUnsubscribers.forEach(unsub => unsub());
  });
  
  return (subscriptions) => {
    // Clean up old subscriptions
    currentUnsubscribers.forEach(unsub => unsub());
    currentUnsubscribers = [];
    
    // Create new subscriptions
    // ... same as useSync but stores in currentUnsubscribers
  };
}
```

### 7. Debouncing Logic

Prevents multiple rapid updates:

```javascript
const pendingReloads = new Set();
let reloadTimer = null;

function handleReload(props) {
  // Add props to pending set
  props.forEach(p => pendingReloads.add(p));
  
  // Clear existing timer
  clearTimeout(reloadTimer);
  
  // Set new timer for 300ms
  reloadTimer = setTimeout(() => {
    const propsToReload = [...pendingReloads];
    pendingReloads.clear();
    
    // Inertia partial reload
    router.reload({ only: propsToReload });
  }, 300);
}
```

## Association Detection

The Broadcastable concern uses Rails reflection to automatically handle associations:

```ruby
if (association = self.class.reflect_on_association(target))
  if association.collection?
    # has_many or has_and_belongs_to_many
    send(target).each do |record|
      broadcast_marker("#{record.class.name}:#{record.obfuscated_id}", 
                      action: "refresh")
    end
  else
    # belongs_to or has_one
    if (record = send(target))
      broadcast_marker("#{record.class.name}:#{record.obfuscated_id}",
                      action: "refresh")
    end
  end
end
```

## Debugging Checklist

### Rails Side

1. **Check Broadcastable is included**
   ```ruby
   Model.included_modules.include?(Broadcastable)
   ```

2. **Verify broadcasts_to configuration**
   ```ruby
   Model.broadcast_targets  # Should show [:all] or [:association]
   ```

3. **Check ActionCable logs**
   ```
   tail -f log/development.log | grep "Broadcasting"
   ```

4. **Verify authorization**
   ```ruby
   Model.authorize_sync(obfuscated_id, user)  # Should return true
   ```

### JavaScript Side

1. **Check WebSocket connection**
   ```javascript
   // In browser console
   window.App.cable.connection.isOpen()  // Should be true
   ```

2. **Monitor subscriptions**
   ```javascript
   // In browser console
   window.App.cable.subscriptions.subscriptions
   ```

3. **Check for errors**
   - Browser console for WebSocket errors
   - Network tab for failed WebSocket upgrade

4. **Verify Inertia props**
   ```javascript
   // In Svelte component
   console.log($page.props)  // Check prop names match
   ```

## Common Issues

### 1. No Updates Received

- Model missing `include Broadcastable`
- Wrong channel format in subscription
- Authorization failing (check SyncAuthorizable)
- WebSocket connection failed

### 2. Updates Not Reflecting

- Prop names don't match controller
- Inertia partial reload failing
- Component not using reactive props ($props())

### 3. Too Many Reloads

- Multiple models broadcasting to same channel
- Debouncing not working (check timer logic)
- Circular dependencies in associations

### 4. Authorization Errors

- User not member of account
- Missing site_admin for :all subscriptions
- SyncAuthorizable not included in model

## Performance Considerations

1. **Marker broadcasts** - Only send minimal data
2. **Debouncing** - 300ms delay prevents storms
3. **Partial reloads** - Only reload affected props
4. **Obfuscated IDs** - Indexed for fast lookups
5. **Channel reuse** - One channel per model/ID combo