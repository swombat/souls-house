# Web synchronization internals

## Source map

- [Broadcastable](../app/models/concerns/broadcastable.rb): after-commit markers.
- [SyncAuthorizable](../app/models/concerns/sync_authorizable.rb): record access.
- [Cable connection](../app/channels/application_cable/connection.rb): signed
  instance-aware browser session cookie.
- [SyncChannel](../app/channels/sync_channel.rb): explicit model/collection allowlist
  and subscription-time authorization.
- [cable.js](../app/frontend/lib/cable.js): consumer, debounce and event routing.
- [use-sync.js](../app/frontend/lib/use-sync.js): Svelte lifecycle helpers.

## Protocol

Streams are named `Model:obfuscated_id`, with specific admin collection streams
such as `Account:all`. `Broadcastable` emits `refresh`/`remove` markers after commit
to the record and declared targets. Parent invalidation causes a prop reload; it
is not a nested object mutation patch.

`subscribeToModel` opens a `SyncChannel` subscription. On ordinary messages it
collects **the client's mapped prop names** and calls `router.reload({ only: props,
preserveState: true, preserveScroll: true })` through a shared 300 ms debounce.
The server marker's `prop` is not used to choose those props in the current code.

For `runtime_activity_changed`, the client dispatches an activity-refresh event.
Specialized streaming/error/debug actions dispatch local browser events instead
of the normal reload. When a `Chat` subscription connects, it also refreshes props
and activity to recover changes missed before connection or during an outage.

Server collection subscriptions enumerate currently accessible members and attach
to their record streams. This is not a durable dynamic collection feed or a
revision cursor. Frontend `/collection` notation must not be confused with the
channel's `id:collection` parsing.

## Authorization and limits

Only allowlisted models/collections can be subscribed. Records require
`accessible_by?(current_user)` and all-record streams require site administration.
The connection identifies a browser session user, not a bearer API resident.
These are subscription-time checks; this mechanism does not promise the continuous
membership-loss fencing required by a future native transport.

There is no replay log, monotonic revision, tombstone feed or exactly-once delivery
contract here. Reconnection uses HTTP re-fetch; never infer an offline-sync protocol
from a green two-window browser test. See [native-client gaps](api.md#before-building-native-clients).

## Debugging order

1. Verify the intended checkout/session and authorized account without dumping
   cookies or tokens.
2. Check that the model commits and declares the correct broadcast target.
3. Check channel acceptance, identifier and allowed collection.
4. Check that the subscription maps to props actually served by that controller.
5. Inspect partial reload responses and the page's state reconciliation. If data
   arrives but a draft disappears, the transport can be correct and the UI wrong.
6. Test disconnect/reconnect and pagination, not only a fresh page load.

Relevant regressions live under `test/channels`, frontend `cable.test.js` and the
chat-state tests, plus the owned-backend Playwright journeys. See [testing](testing.md).
