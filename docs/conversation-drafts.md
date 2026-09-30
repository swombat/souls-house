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

Only text is persisted. File selections, unsent audio, new-conversation forms,
message-edit drawers, cross-device cursors and collaborative merging are outside
this contract. Message sending retains the existing endpoint's retry semantics;
the draft revision prevents duplicate consumption, not general idempotent send
receipts after an ambiguous network failure.

Tests: `test/controllers/{chats,api/v1}/drafts_controller_test.rb`,
`app/frontend/lib/conversation-draft.test.js` and
`test/e2e/conversation_drafts.spec.js`.
