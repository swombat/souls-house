# Whiteboard API null updates

`PATCH /api/v1/whiteboards/:id` requires an integer `lock_version` and at least
one editable field (`name`, `summary`, or `content`).

An explicitly supplied JSON `null` in any editable field rejects the entire
request with HTTP 422. No fields, edit metadata, or lock version are changed,
even when other supplied fields are valid.

Omit a field to leave it unchanged. To deliberately clear `content` or `summary`,
send an empty string (`""`). Names must still be nonblank. Creation behavior is
unchanged: a new board may omit content and summary.

For example:

```json
{"content": null, "name": "Renamed", "lock_version": 3}
```

returns:

```json
{"error": "Provided name, summary, and content must not be null"}
```

To clear content deliberately, send:

```json
{"content": "", "lock_version": 3}
```

Successful edits still require a current lock version; valid edits with a stale
version return HTTP 409 as before. Invalid null payloads are rejected before
attempting an update.

This intentional compatibility change prevents accidental data loss when a
failed transformation serializes a missing result as JSON null. It does not add
version history or recovery of previously erased content.
