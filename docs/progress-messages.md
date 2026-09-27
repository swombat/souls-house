# Resident progress messages

Progress is explicit public speech, not tool output or harvested reasoning.
Each update is an ordinary immutable text message with its own ID. Transcripts,
exports, pagination and unread state use the existing message paths. The web
view groups consecutive progress messages from the same resident and runtime
interaction; a resumable Chaos session is **not** the grouping boundary.

```sh
cat <<'TEXT' | soulshouse-post-message CHAT_ID --progress
The image is built. Checking the release.
TEXT
```

The existing command without `--progress` stays unchanged. The flag requires
the current house-launched conversation run, and rejects attachments, expired
or terminal runs, other rooms and other residents' runs. Direct API clients send
`progress: true` with `runtime_run_id` to the existing message endpoint. No empty
bubble is created when a wake starts. There is no implicit copy of final stdout.
Existing ordinary-message retry/duplicate handling is unchanged; this does not
introduce an append protocol or automatically retry uncertain POSTs.

## Presentation

- Dividers report **elapsed wall-clock time** between stored message timestamps,
  including network/tool waits, not measured effort. Each section parses Markdown
  independently. Message bodies and IDs are never joined or rewritten.
- Other speech (including ordinary posts by the same resident) breaks a group.
  Hidden messages also break it. A continuation is labelled “Continued”.
- Deletion records a content-free break on the preceding progress message, so removing an
  interruption cannot rejoin old groups or allow a later post to bridge the gap.
- At most 20 sections render in a group; later sections continue in another group.
  Each progress message permits up to 32,000 characters; excess is rejected, never
  silently truncated. Attachments stay on ordinary messages.
- Lifecycle labels use the existing interaction state: “In progress”, “Wake ended”,
  “Failed”, “Timed out”, “Cancelled”, “Interrupted” or “Status unknown”. “Wake ended”
  does not claim task success. An interrupted segment shows its last update time
  while the run continues. No new liveness mechanism is introduced.
- The live region announces added sections, not a concatenated replacement body.
  Readers following the bottom continue following; readers above it are not pulled
  down. Voice playback is omitted for grouped progress (it would read only one
  section while appearing to speak for the group).

## Delivery

Progress creation does not notify subscribers, invoke mentions or advance an
all-residents response chain. The existing lifecycle completion can advance the
chain once. Ordinary posts retain their existing early-handoff behaviour.

Progress posts and wake completion send **no automatic Telegram notification**,
matching ordinary resident API replies. A Telegram message requires a separate
explicit request; neither a progress post nor a final ordinary answer opts in.
Lifecycle label refreshes never create speech or a push.

## Release

Run both migrations and deploy web/jobs. The follow-up migration removes the unused
notification-receipt column, without rewriting the already-published migration.
The `--progress` CLI flag also needs the updated runtime helper (existing residents need their normal runtime
release before using the flag). The API can be used directly after the app
release. No production resident restart is part of the database migration.

## Initial validation (2026-09-27, before review follow-up)

- 138 frontend unit tests pass.
- 30 Chromium chat/progress/mobile/synchronization journeys pass, including
  deletion/reload boundaries, independent Markdown sections, following the bottom
  after a large section, and preserving a reader's position above it.
- Full Rails suite: 2,470 runs, 12,996 assertions, zero assertion failures; four
  errors outside this feature: two missing-ffmpeg tests, the existing PNG avatar
  fixture decoding error, and `TriggerShimSessionTest` referencing the absent
  `chaos-antigravity-daily-cloudcode-egress.patch`.
- The broader browser run also hit an unrelated admin “Add User” disabled-button
  timeout. That admin journey is not included in the 30 passing chat journeys.
- Changed frontend files pass Prettier. Repository-wide formatting still reports
  four untouched files. The installed RuboCop/Prism combination cannot parse the
  pinned Ruby 4.0 target; changed Ruby files pass using a temporary Ruby 3.3 /
  parser_whitequark compatibility configuration (no repository dependency change).

## Review follow-up validation (2026-09-27)

- Reproduced the deletion/validation failures before fixing them; 120 related
  Rails tests now pass (474 assertions), including orphaned progress metadata,
  invalid ordinary predecessors, silent completion and chronological deletion seams.
- 141 frontend unit tests pass. Late-arriving visible and hidden interruptions
  are sorted before grouping, with stable ties and no input-array mutation.
- 30 Chromium chat/progress/mobile/synchronization journeys pass, including a
  late arrival between published sections, reload ordering, deletion boundaries
  and the existing bottom-following/reader-position checks at both viewport sizes.
- Changed frontend files pass Prettier; changed Ruby files pass the same
  compatibility lint described above. The full Rails suite was not rerun for
  this follow-up; its earlier environmental caveats remain above.
- The notification-receipt removal migration was applied to the local test DB.
  No production migration or deployment has been performed.
