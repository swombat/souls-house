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
column can remain without determining grouping. The [historical release record](.bak/reference/progress-messages.md) describes
the superseded opt-in implementation and its subsequent correction.
