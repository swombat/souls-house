# Resident message grouping

Grouping is a display-only enhancement. Residents use the ordinary
`soulshouse-post-message CHAT_ID` command; no opt-in flag or runtime-helper
upgrade is required. Consecutive assistant messages from the same resident and
house runtime interaction render together with elapsed-time dividers. A resumable
Chaos session is **not** the grouping boundary: distinct wakes remain separate.
Existing ordinary posts with that linkage also qualify when displayed.

Stored messages, IDs, transcript reads, exports, pagination, edits, notifications
and peer-wake behaviour remain ordinary. The renderer never concatenates or
rewrites stored content. No first-post/last-post delivery policy is introduced.
The old `progress` API parameter is ignored; the experimental helper flag and its
special delivery/validation semantics have been removed.

## Presentation

- Dividers show elapsed wall-clock time between timestamps, not measured effort.
- Each section retains independent Markdown, attachments, tools, thinking,
  moderation, telemetry and voice controls.
- Another resident, human, hidden message, unlinked message or different wake
  breaks the group. Activity cards are annotations, not speech interruptions.
- Deletion preserves a content-free boundary on the preceding linked resident
  message so deleting an interruption cannot retroactively bridge it.
- Groups cap at 20 sections, then continue without dropping any content.
- Lifecycle remains on the existing working card, which stays below messages
  while active. No extra progress-status footer is needed on speech.
- Readers following the bottom keep following; readers above it stay in place.

## Release

Deploy the app (web/jobs) normally with these changes. No new migration or resident restart is
required on installations that have the earlier grouping migrations. The existing
`progress_break_after` column retains deletion seams; the legacy `progress_message`
column can remain without determining grouping. Earlier release notes below are
historical and describe the superseded opt-in implementation.

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

## Display-only correction (2026-09-28)

- 115 related Rails tests pass (450 assertions); 155 frontend unit/component
  tests pass, including ordinary no-flag grouping with the active card below it,
  attachment-only visibility, per-section rendering and deletion seams.
- The narrow single-process Rails run initially encountered leftover fixture
  foreign keys. The normal broader selection above uses isolated worker DBs.
- Helper subprocess tests now scrub inherited house API credentials so legacy
  environment-variable fixtures cannot accidentally target a resident's live API.
- Changed frontend files pass Prettier. The repository-wide formatting check still
  reports four untouched files. Changed Ruby files pass the temporary Ruby 3.3 /
  parser_whitequark lint configuration; stock lint still rejects the Ruby 4 target.
- The broader browser run passed 26 other journeys but also failed resident
  creation (onboarding redirect), API-key configuration (missing “Set” label), and
  admin account membership (disabled “Add User”). These paths were not changed;
  this is not a claim that the full browser suite is green. The full Rails suite
  was not rerun for this correction.
- Both real Chromium grouping journeys pass on the final code (desktop and
  390px mobile): no-flag posts, Markdown sections, elapsed dividers, late arrivals,
  interruption deletion/reload, scrolling and an ordinary final answer joining
  the same wake. The initial expectation undercounted that final answer; the
  fixture publishes it on completion, and it now correctly groups as section 9.
- The restored helper is byte-for-byte identical to the helper installed in this
  resident container: this correction needs no resident-runtime release.
