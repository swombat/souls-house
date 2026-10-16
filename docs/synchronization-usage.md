# Web synchronization usage

The current web client uses Action Cable invalidation plus Inertia partial reloads,
not a replicated data store. See [internals](synchronization-internals.md) for
protocol details and [API boundaries](api.md) before reusing it for native clients.

## Model changes

Models include `Broadcastable` and declare related targets, for example:

```ruby
class Message < ApplicationRecord
  include Broadcastable
  broadcasts_to :chat
end
```

The actual model also declares associations, validation and other concerns; this
snippet shows only the synchronization hook. After a committed change, the record
and configured parent targets receive refresh markers. Clients refetch the props
mapped to their subscription; these markers are not full record payloads.

## Svelte subscriptions

Use the public helpers in [use-sync.js](../app/frontend/lib/use-sync.js):

```svelte
<script>
  import { useSync } from '$lib/use-sync';
  let { account } = $props();
  useSync({ [`Account:${account.id}`]: 'account' });
</script>
```

`useSync` sets subscriptions on mount and removes them on destroy. If IDs or the
subscription set change while the component stays mounted, use `createDynamicSync`
and update it inside an appropriate effect. Values can name one prop or a list.
Use actual Inertia prop names; choosing an arbitrary model property does not make
it a reloadable prop.

Allowed models/collections are explicit in `SyncChannel`. Broad `Account:all` and
`Setting:all` streams are site-admin-only. Membership and record authorization are
server-side checks, not client convention. A `/collection` suffix in the frontend
helper is not a wildcard subscription to arbitrary associations.

The Field uses the account-authorised, content-free `FieldActivity:<account-id>`
stream. It covers committed item/tag mutations, including new arrivals; it does
not expand a collection into whichever records existed when the socket connected.
Do not substitute the broad Account stream: unrelated chat writes also reach it.
Field list/count/selected-item props refresh together, while an open search keeps
its requested result window until the reader searches or navigates again. Note
drafts retain both their text and the revision they started editing.

Room metadata uses the account-authorised, content-free
`RoomNavigation:<account-id>` stream, including committed reorders whose position
writes bypass ordinary model callbacks. The navbar watches the current account
even when it has no rooms yet. Room settings keep conversation counts separate
from room metadata, so unrelated chat activity need not reload room names/order.
Do not map room metadata to all confirmed accounts or the run-state
`RoomActivity` stream.

## Conversation state

Chat connection/reconnection schedules a prop refresh to catch changes missed
while disconnected; socket broadcasts are not replayed. Conversation pages also
manage loaded message windows, drafts and viewport state. Reuse the existing
`chat-*` helpers and tests rather than replacing them with a wholesale prop-copy
effect that resets local input.

`streamingSync` handles legacy/specialized stream events separately. Runtime
activity refreshes and normal message reloads are distinct paths. Ordinary hosted
resident replies are persisted API messages, not a Rails token-stream executor.

For verification, test two authenticated browser windows, reconnect behaviour,
message pagination and draft preservation. Do not use live providers or resident
wakes to test UI invalidation.
