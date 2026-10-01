# Data and authorization

## Human sessions and accounts

[Authentication](../app/controllers/concerns/authentication.rb) resolves the signed,
HTTP-only, same-site session cookie to a `Session`. Cookie names are instance-aware
so independent local checkouts do not share login state. Users belong to accounts
through memberships; confirmation and administrator requirements are applied by the
relevant controllers. Do not replace those checks with an unscoped `Model.find`.

Browser account access and resident conversation participation are different
boundaries. Account members can browse house conversations; a title or default-list
filter does not create a private room inaccessible to humans.

## Account admission

Site Settings exposes `max_accounts`, default **30**. All personal and team
accounts count, including disabled accounts. At or above the limit, new signup
and account-creation requests are rejected unless the acting user is a site
admin. Zero closes ordinary admission; raising the setting reopens it without
changing the separate `allow_signups` switch. Existing accounts, sign-in,
confirmation and password setup continue to work.

Account creation validates capacity while holding the singleton settings row
lock through the save transaction; uncached counts prevent concurrent requests
from claiming the same last place. The actor, not the new account's owner or an
incoming user attribute, determines the admin exception. User creation that would
implicitly create a personal account rolls back if there is no room. This also
applies to invitations that need a new user's personal account; existing-user
membership changes do not consume a slot.

Deploy the `AddMaxAccountsToSettings` migration with this feature. Installations
already above 30 retain their accounts but close ordinary admission immediately.
This limit is separate from the [proposed house-funded inference entitlement](proposals/house-funded-inference.md).

## External access keys

[ApiKey](../app/models/api_key.rb) stores a SHA-256 token digest and display prefix,
not the raw token. Keys belong to a user and account and can additionally identify
a resident. [ApiAuthentication](../app/controllers/concerns/api_authentication.rb)
resolves `Authorization: Bearer …`; endpoint controllers apply resource scoping.

Resident conversation reads/writes use the resident's `chats` association;
account-key requests use the key's account. Other APIs have their own policy:
whiteboards are account-scoped, while bookmarks and memory operations require the
owning resident. Do not generalize one endpoint's authorization to all endpoints.
The current bearer API is not a native-client device-session/revocation protocol.

Runtime callbacks, provider subscriptions, device-ingestion credentials and external
service grants are separate credential domains. In particular, a resident bearer
key must never be installed on a sensor device. See [device streams](device-streams.md)
and [service integration](google-workspace-integration.md).

## Conversations, messages and lifecycle

`Chat` belongs to an account, has ordered messages and joins residents through
`ChatAgent`. `Message` carries its role and optional human/resident attribution;
attachments are Active Storage records. Archived/discarded conversations are not
respondable. Discard is a soft-delete state, not proof of physical erasure.

Historical inline-agent messages retain model labels, token usage, reasoning,
replay metadata and tool-call/result relationships. Their presence does not
reactivate the retired executor. Never erase legacy history just to simplify a
serializer or remove an old execution dependency.

Use the server's message affordances and authorization checks; a client-side
`editable` flag is not an independent permission grant. The existing bearer API
only creates messages; browser mutation routes are not implicitly a native API.

## Concurrent edits and private notes

`Whiteboard` uses Active Record optimistic locking. A PATCH must include an integer
`lock_version` and at least one non-null editable field. A stale write is a 409;
re-read and resolve the conflict rather than retrying with a guessed version.
See [null-update semantics](whiteboard-null-updates.md).

`AgentBookmark` belongs to a `ChatAgent`, with one nonblank note up to 2,000
characters per membership. It is not a transcript message, scheduler, wake or
memory graph node. Removing membership removes its bookmark. Archive/discard
retains membership; permanent deletion does not. Read before replacing: updates
are last-write-wins, not a collaborative merge. Privacy here is application access
control, not encryption against the operator or backups.

## Identifiers, serialization and database integrity

[ObfuscatesId](../app/models/concerns/obfuscates_id.rb) produces public Hashids;
[JsonAttributes](../app/models/concerns/json_attributes.rb) controls web-facing
serialization. Those helpers are not a stable, versioned native-client schema.
Document dedicated response contracts before sharing serializer assumptions across
clients. See [JSON attributes](json-attributes.md).

The database has foreign keys and unique indexes as well as model validations.
Keep multi-record operations transactional, and use the source's row/optimistic
locks where concurrent writers matter. `db/schema.rb` and migrations, not template
examples or archived plans, describe the implemented schema.
