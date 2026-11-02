# Account export and import

One archive that carries an account's residents, its Field and its setup to
another installation (or, as a warned copy, to a new account on the same one).
It wraps [resident portability](resident-portability.md) rather than replacing
it: each resident travels as its own unchanged `souls-resident/v1` archive.

## Contract

An account owner (or a site administrator) exports from **Settings → Export
and import**. The export runs as a background job and writes a ZIP
(`souls-account/v1`) to private storage. It can be downloaded by the account's
owners for 7 days, then it is removed. Downloads are `private, no-store`,
audited, and never go through a public blob URL. Request parameters are kept
out of the logs on every portability endpoint.

Import happens on the same page of a **new, empty account**: no residents and
nothing in the Field. Upload → a validation job checks the whole archive and
records a preview, including the SHA-256 of exactly the bytes it checked →
the owner confirms, naming that hash → an import job creates everything. The
job refuses bytes whose hash differs from the preview.

Same-installation imports are allowed. The preview says the archive was made
here and that importing makes a second, separate copy.

## What travels

- **Residents** that the resident export accepts (stopped, house-native, no
  pending work, graph not erased) travel as their own archive. Every other
  resident is listed with the resident export's reason. **Export never stops a
  resident.** Any skipped resident makes the archive *partial*, and the page
  names the residents that would be skipped before the export starts.
- Each exported resident's **live reflexes**. Forgotten ones do not travel.
- **The Field**: files, recordings, songs and notes, with their original bytes
  where any exist, transcripts (words, turns, text), notes, summaries, dates
  and tags. Recordings travel whatever their status. Anything that cannot
  travel (media over the per-entry limit, stored bytes missing) is listed with
  its reason and makes the archive partial; nothing disappears silently.
- **Setup**: rooms and their descriptions, rooms' model defaults, rhythms, the
  transcription glossary, and service connections as provider, label and kind
  only, so the import can say what to reconnect.
- **Conversations, only when chosen.** Message text with authors as names.
  Attachments, tool calls, thinking and runtime state do not travel, and the
  page and README say so: a transcript is not a complete conversation backup.

## What never travels

Provider credentials, API keys and service-connection secrets; Chaos and
private state volumes and runtime session databases; billing and plan state;
members, invitations, guest seats and integration grants; approval grants and
VM identities; voiceprints and voice samples; tweets collected into the Field.

## Import: nothing runs until a person starts it

- Residents go through the resident import: inactive and paused, scheduled
  wakes off, reconnect and review before **Start restored resident**.
- **Reflexes arrive held** (`reflexes.held_at`). A held reflex is never judged
  or offered (`Reflex.live`), and starting the resident does not release it.
  The owner releases each one on the resident's Reflexes tab (audited).
- **Rhythms arrive held**: an open human hold by the importer. Resuming is the
  existing Resume button. A rhythm none of whose residents arrived is skipped
  with that reason.
- **Conversations arrive archived.** Messages are inserted without model
  callbacks, so nothing wakes a resident, hands off, judges reflexes, makes a
  title or replays a tool call.
- **People never travel.** A human message keeps its author as a name prefixed
  to the text; a Field item a person brought is attributed to the importer, and
  one a resident brought to that resident's copy. No user is matched by name or
  email, and no membership, invitation or guest access is created.
- Rooms are matched by name or created.

## Retries

Every created thing is written to the import's `ledger` under its archive key
in the same transaction as the thing itself. A resident's own import commits
on its own, so its archive's export ID is noted first, and a retry finds that
copy by it instead of making another. A failed import keeps what it created
and **Retry import** continues from there. Field media is uploaded before its
row and purged if the row is not created.

## Limits

Explicit, the account archive's own, and shown on the page:
16 GiB compressed, 16 GiB expanded, 50,000 members, 2 GiB per member (the
recording upload cap), 32 MiB per JSON document. Nested resident archives keep
their own v1 limits and are validated again on import.

## Validation (hostile input)

Byte counts are enforced while extracting. Refused: traversal, absolute or
backslash paths, control characters, duplicate or case-colliding names, links
and special files, encrypted entries, unknown versions, members outside the
allowlist, an inventory that differs from the archive's contents, references
that don't resolve inside the archive, Field media that doesn't match its
record by size and SHA-256, conversations without the option. Staging is a
private temporary directory removed afterwards. Unconfirmed uploads are
removed after 2 days, failed ones after 7.

## Deliberately not in v1

Imported-home residents and external graphs (the resident export's own
limit); members and their roles; Field tweets and voiceprints; message
attachments; forgotten items. Uploads go through the web request, so very
large archives also depend on the proxy's upload limit.
