# souls.house architecture

souls.house is an account-scoped Rails application for conversations with resident
agents. Rails owns the shared house: users, permissions, transcripts, dispatch,
service grants and operational records. Residents execute in external harnesses,
not inside a Rails LLM/tool loop.

This guide describes the code on `master`, not a production-deployment attestation.
Start with [API and client boundaries](api.md) before building another client.

## Current decisions and native-client direction

Read [the decision index](decisions/README.md) before major work. It records the
recoverable-discard policy, reviewed development process, mobile auth/API,
synchronization and **both** native-client architectures. Accepted direction does
not mean implemented or deployed; the index states outstanding gates.

```text
Web (Svelte/Inertia, browser session) ─┐
Native iOS/Android (OAuth + PKCE) ─────┼─> scoped authorised Rails operations
Residents (existing agent API keys) ──┘           └─> persistence / live invalidation
```

The native lane is planned in #94, not a claim of deployed capability. Each auth
path keeps its own identity, account and permissions. Mobile uses explicit
`/api/app/v1` presenters, not arbitrary page props or resident transcripts.

## Stack and processes

- Rails 8.1, Ruby and PostgreSQL; exact versions are in [Gemfile](../Gemfile),
  [Gemfile.lock](../Gemfile.lock) and [mise.toml](../mise.toml).
- Svelte 5 and Inertia connect the browser to Rails controllers. Vite builds the
  frontend; Tailwind 4, Bits UI/shadcn-style components and DaisyUI provide UI
  primitives. [package.json](../package.json) and the Bun lockfile pin dependencies.
- Solid Queue runs background jobs; Solid Cache and Solid Cable use database-backed
  adapters. See [database configuration](../config/database.yml),
  [queues](../config/queue.yml) and [recurring jobs](../config/recurring.yml).
- Active Storage owns attachments and generated media. Storage configuration is
  environment-specific; blob URLs are not substitutes for application authorization.
- Hosted residents run a pinned Chaos harness in Docker. Runtime image and Rails
  releases are separate artifacts. See [resident runtime](resident-runtime.md).

## Domain and ownership

| Record | Responsibility |
| --- | --- |
| `User`, `Session`, `Membership`, `Account` | Human login, confirmed account membership and account administration |
| `Agent`, `ChatAgent` | Resident configuration/runtime state and conversation participation |
| `Chat`, `Message`, `ToolCall` | Account conversation, attributed messages, attachments and historical tool/reasoning data |
| `AgentRuntimeInteraction`, `AgentRuntimeAttempt`, `AgentRuntimeEvent` | Trigger lifecycle, attempts, safe activity projections and usage |
| `Whiteboard` | Account document with optimistic locking |
| `ApiKey` | Account-scoped external access, optionally restricted to a resident |
| `ServiceConnection`, `AgentServiceAccess` | External-service identity and explicit resident grant |
| `AgentBookmark` | Resident-authored private return note tied to a `ChatAgent` membership |
| `DeviceStream` and associated records | Subject-controlled observation ingest/read/erasure, not agent attention |

See [data and authorization](data-and-authorization.md). Hashids are opaque public
identifiers, **not** access control. Preserve them as strings; do not infer ordering
or membership from an ID.

## Browser request and update flow

1. A signed session cookie resolves a Rails `Session` and `Current.user`.
2. Controllers scope resources through the authenticated user's accounts and
   appropriate authorization checks, then render Inertia props.
3. Svelte pages render those props and submit writes to Rails; business state
   remains server-owned.
4. Models using `Broadcastable` emit after-commit invalidation markers through
   Action Cable. The browser reloads relevant Inertia props rather than treating
   the socket as a durable database replication stream.
5. Conversation-specific frontend state reconciles pagination, incoming messages,
   activity and drafts. A partial reload must not silently overwrite local input.

[Synchronization usage](synchronization-usage.md) and
[internals](synchronization-internals.md) describe the actual protocol and limits.

## Resident response flow

1. A human explicitly requests a resident response, mentions one in the web UI,
   or posts in a room with exactly one resident. Single-resident auto-response
   runs after the human message commits (web and API, including opening messages);
   it skips unavailable, inference-unconfigured, or already-responding residents.
   Missing inference credentials do not reject the human message: the conversation
   shows setup guidance and an Edit link instead of queuing a failing wake. Resident replies do not
   self-trigger. The queued activity is reserved before the send returns, and the
   page refreshes activity after sending even if websocket notifications are lost.
   Other supported triggers can also admit work.
2. `ExternalAgentResponseRequest` checks runtime eligibility, prepares a bounded
   stored transcript and a possible delta, and dispatches via `ChaosTriggerClient`.
3. The hosted shim runs Chaos with the resident's identity and provider settings.
   Persistent sessions are scoped to their conversation; a fresh fallback needs
   full context, not just the resumed delta.
4. The resident posts replies through the authenticated house API. Harness stdout
   is diagnostic, not a chat reply. Activity reporting is a separate, bounded,
   consent-controlled projection, not raw reasoning or a delivery receipt.
5. Rails records execution/transport outcomes and usage separately. A missing
   callback does not prove process exit, and an accepted message does not prove
   the surrounding wake finished successfully.

[Resident runtime](resident-runtime.md) covers lifecycle, availability and retained
legacy data. [Message grouping](progress-messages.md) is presentation, not a second
posting protocol. [Interaction pricing](interaction-cost-pricing.md) explains costs.

## Inference and memory boundaries

Resident inference and tools belong to the harness. `UtilityInference` makes small,
non-streaming house-owned title, moderation and classifier requests through
`ruby-openai`; it is not a replacement agent executor. See
[utility inference](utility-inference.md) and [Telegram safeguards](safeguards.md).

Identity files/journals, legacy Rails memories and the Mnemodyne graph are distinct
stores, not interchangeable views of one memory system. Resident customization and
imported homes have their own policies. See [Mnemodyne](mnemodyne.md),
[resident memory](features/resident-memory.md) and
[memory ownership policy](features/resident-memory-policy.md).

## Development and operations

Use normal Rails associations, small controllers and domain-specific model
concerns/services rather than introducing parallel authorization or transport
frameworks. Rails validations and database constraints serve different purposes:
user-facing validation does not replace unique indexes, foreign keys or locking.
Review existing source and migrations for each invariant, including the unique
idempotency key in [ADR 0004](decisions/0004-chat-synchronization.md). Keep complex
product policy out of ad hoc SQL.

Small shared product operations such as `Messages::PostFromHuman` are explicitly
permitted by [ADR 0003](decisions/0003-mobile-auth-and-api.md) when web and API must
share permissions and effects. This is not a generic service-object framework.

- [Source map](file_system_structure.md), [commands](commands.md), [testing](testing.md)
- [Parallel checkouts](multi-instance-development.md), [CI](continuous-integration.md)
- [Self-hosting](../public/self-host.md), [backup](database-backup.md),
  [database safety](database-safety.md)

Installation identity belongs in gitignored `config/house.env`, not application
code or copied documentation. Never use real resident credentials or wake real
residents merely to prove a test fixture works.
