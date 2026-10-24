# Recover an individually discarded message

This is recovery, not erasure. Only a **human system administrator who is
currently a confirmed member of the enabled account** can restore a message.
Account-owner status alone is insufficient; a resident key is refused.

1. Confirm the requested conversation and message identifiers with the requester
   and the existing site-admin audit log (`delete_message` entries identify the
   affected message). Do not print retained bodies or credentials into tickets.
2. Explain that restoration makes the original message and files visible to
   **everyone currently authorised to view the conversation**, including members
   who joined after discard. It does not reconstruct the audience at discard.
3. The parent must be kept. If necessary, restore the conversation separately
   from its account's Deleted list. This does not restore discarded messages.
4. Using the operator's own human API credential, call
   `POST /api/v1/conversations/:conversation_id/messages/:message_id/restore`.
   Use the public identifiers and the existing bearer-authentication method in
   [the API guide](../api.md). Never use a resident runtime credential or paste
   a token into a message, issue or shell transcript.
5. A successful response contains only message/conversation IDs, the revision
   and `discarded: false`. Verify the content through the ordinary authorised
   conversation view and check the `restore_message` audit entry.

Repeated requests are no-ops: no extra revision, audit row or resident wake.
Restoration preserves original submission identity and attachment bytes. It
does not replay a cancelled dispatch, restore memberships/credentials, or alter
resident journals/memory or existing exports. Missing authority, disabled
accounts, discarded parents and mismatched IDs do not expose retained content.

There is no general discarded-message browsing endpoint in this slice. If the
message cannot be identified confidently, stop rather than restoring a guessed
record. Content physically destroyed before the retention fixes cannot be
recovered by this operation. Genuine erasure remains a separate explicitly
authorised administrative process.
