# Synthetic mobile contract examples

Hand-authored, non-production data checked against merged backend commit
`058f89e1fdede8a7cdb39b951d36b7751e0fb892`:

- `app/controllers/api/app/v1/presenter.rb`: message fields, six-digit ISO timestamps,
  nullable client identity, positive body-free discard markers.
- `app/models/message.rb#author_type`: `human`, `agent`, `system` author tags.
- `changes_controller.rb`: `changes`, `next_since`, `has_more`, `latest_revision`.
- `messages_controller.rb`: history, exact retry payload, accepted/discarded send.
- `base_controller.rb`: error envelope.

These are examples, not generated server snapshots or a comprehensive API schema.
Both platform suites consume the same JSON bytes. No credentials, real people,
real conversation IDs or storage URLs belong here.

`changes-first` starts at since=0: cursor becomes **4**, not advertised head 9.
Head 9 intentionally exceeds the returned rows to catch unsafe cursor promotion.
`changes-discard` continues from cursor 4: a discard at 7 and updated reply at 9
finish that head; `changes-empty` follows at cursor 9.
Applying `history-stale` after the discard must not resurrect `msg_alpha`.
`changes-unknown` exercises additive fields and unknown enum-like values.
`send-discarded` is an accepted retry, not a reason to restore its old content.
Missing history rows are never removal markers. IDs are opaque strings.

`changes-null-content` represents a permitted nullable message body (schema and
model allow it for assistant/tool rows); synchronization must advance past it.
