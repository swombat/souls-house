# Private conversation drafts

Existing conversation composers store one text draft per human author and chat.
The account is inherited from the chat. Drafts are not messages, shared Inertia
props, audits, agent context or account broadcasts; they never trigger a resident.
They are not encrypted against the server operator or database backups.

## JSON contract

- Browser session + CSRF: `GET/PATCH /accounts/:account_id/chats/:chat_id/draft`.
- Human-owned account bearer key: `GET/PATCH /api/v1/conversations/:id/draft`.
  Resident-scoped keys are refused, including keys owned by the draft author.
  Both surfaces require the author's current confirmed membership in an enabled
  account. Site-admin browsing privileges do not widen draft access.
  Web editors send `X-Draft-User` on reads, writes and sends; a mismatch against
  the current session is refused to protect tabs left open across a login switch.
- Reads return `{draft: {content: "...", revision: 0}}`, with `Cache-Control:
  no-store`. A first read creates an empty revision-zero record.
- Writes require both a string `content` (at most 100,000 characters) and the
  last observed `revision`. Empty strings deliberately clear drafts. Missing,
  null or structured text is rejected. Success returns the new revision.
- A stale/missing revision returns 409 with the current draft. Revisions are
  compared under a row lock, not timestamps or last-write-wins.
- To send, include `draft_revision` alongside the normal message parameters
  (web `message[content]`, API `content`). The content must match that revision.
  Message validation/save and clearing the matching draft are one transaction.
  A stale revision/content returns 409 without posting. Success includes `draft`
  with empty content and an incremented revision. Legacy sends without the
  parameter do not touch drafts. A duplicate web-send acknowledgement without
  `draft` does not consume a draft.

Empty draft rows are retained so delayed/offline autosaves cannot resurrect a
consumed revision. Hard-deleting a chat or author removes its drafts. Archived
chats can retain draft text but cannot receive messages.

This is the current human-key API, **not** native device-session authentication.
A future native API adapter must enforce its own live user/membership authority
and call the same `ConversationDraft` methods; native client UIs are not added by
this change.

## Browser recovery and concurrency

Every input writes a recovery copy to localStorage scoped by user/account/chat
and a unique editor ID. Separate editors cannot overwrite each other's offline
copies. One pending local copy restores automatically; multiple copies remain
available for explicit recovery. A stale local copy is never automatically
promoted over a different server revision, including an empty sent/discarded
revision. Local copies persist until saved, explicitly replaced, or cleared on
successful web logout. They are plaintext browser storage, not encrypted.

Server autosave debounces 400ms, with a 2s maximum delay while typing. Opening,
focusing, reconnecting online and a 15s visible-page poll reconcile the draft.
This first version does not need a new cable channel. Offline time is not a sync
deadline; the UI distinguishes server save failure from local recovery failure.
Storage failure does not prevent server autosave.

Incoming changes update a clean editor. With pending edits, both texts remain
visible and the author chooses which to keep (or copies/combines them first).
Send waits for autosave. During sending, further typing stays local; only the
acknowledged revision clears, and newer text rebases onto the returned revision.
Navigation/refresh does not depend on an unload-time network request.

Only text is persisted by the server-synced conversation draft protocol. File
selections, unsent audio, message-edit drawers, cross-device cursors and
collaborative merging are outside this contract. Message sending retains the
existing endpoint's retry semantics;
the draft revision prevents duplicate consumption, not general idempotent send
receipts after an ambiguous network failure.

Tests: `test/controllers/{chats,api/v1}/drafts_controller_test.rb`,
`app/frontend/lib/conversation-draft.test.js` and
`test/e2e/conversation_drafts.spec.js`.

## New-conversation browser drafts (#132)

The new-conversation composer (both the account conversation index and `/new`)
is a separate, **browser-local** draft, not a server-synced conversation draft.
It stores message text, title and selected resident IDs synchronously on input,
under one localStorage key per authenticated user/account/new composer:
`conversation-draft:v1:<user>:<account>:new`. It never persists without an
authenticated user. Switching user or account restores that scope before writing.
Title input is saved even before accepting the rename; Escape restores the
previous title. Restored resident selections are intersected with the current
resident list, never expanded to include new residents or replaced with default
selections when empty. Paused residents are not selected by default, but an
explicit saved selection remains selected if still present.

Tabs use **last-write-wins** for that single slot, as approved in
[#132](https://github.com/swombat/souls-house/issues/132#issuecomment-5952571491).
There is no recovery chooser or cross-device synchronization. Each tab restores
on opening; it does not live-merge another tab's edits. Storage is plaintext
and is accessible to people/scripts with access to the browser profile. Closing
or reloading retains it; browser storage deletion/private browsing policies may
remove it. Successful logout uses the existing current-user draft cleanup
prefix and logout marker, and suppresses stale editor/callback writes.
Storage failures show a warning and do not prevent composing or sending.
Files, audio recordings and signed audio IDs are never restored. Transcription
text is persisted before the existing automatic send begins.

Each explicit create attempt generates a fresh `draft_submission_id`, saves it
with the local copy, and captures the author in `X-Draft-User`. Rails refuses a
header mismatch against the current session. Only an actual successful create
returns `flash.draft_submission_id`. The frontend clears only after Inertia
`onSuccess` receives that exact nonce, and deletes storage only if its serialized
bytes still match the submitted copy. Different/newer tab edits survive, even
when the text is identical. Refusal redirects without a matching receipt,
validation failures, cancellation and interrupted requests retain the copy
across remount/reload. A restored submitting nonce displays “may already have
been sent; check the sidebar” before retrying.

**The nonce is an acknowledgement, not an idempotency key.** An uncertain retry
can create another conversation; first check the sidebar. A retry uses a fresh
nonce so an older acknowledgement cannot clear it.

Unit coverage: `app/frontend/lib/new-conversation-draft.test.js` and
`app/frontend/pages/chats/new.test.js`. Browser regression coverage:
`test/e2e/new_conversation_drafts.spec.js`.
