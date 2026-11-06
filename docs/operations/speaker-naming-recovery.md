# Recover a retired Field speaker naming

Moving a speaker's last line away retires the `FieldRecordingSpeaker` row
instead of destroying it. The row keeps its label, voice link and naming
provenance. It is hidden from current speaker lists, naming decisions and
recognition. Its label remains reserved; it does not count toward the active
speaker limit. No historical rows can be reconstructed for speakers destroyed
before this change.

This is **naming recovery, not biometric recovery**. Retirement deletes the
speaker's samples and clears its probe, suggestions, recognition results and
sample-review evidence. Recovery cannot bring those back. Biometric Forget
remains irreversible. A retained row follows later changes to its linked voice:
delete-name clears its naming, merge moves the link, and Forget does not erase
the authored name. Do not restore a deleted name from a backup or copy an old
voice link over the row's current state.

## Authority and preflight

Only a human system administrator should run this procedure, on an authorised
request from someone with current access to the recording's account. Console
access bypasses request authorisation; the model methods are not a new access
grant. Verify the requester, account, recording and intended line before any
write. Do not paste private names, transcript text or provenance into a public
room. There is no recovery endpoint and retired speakers are not offered in the
ordinary reassign picker.

In an authorised Rails console, scope through the identified account:

```ruby
account = Account.find(account_id)
recording = account.field_recordings.kept.find(recording_id)
history = recording.speakers.retired.order(:retired_at)
history.map { |s| [s.id, s.label, s.field_voice_id, s.naming_source, s.named_by_type, s.named_by_id, s.named_at, s.retired_at] }
```

Show only the necessary choices to the requester privately. Confirm the
retained naming is still wanted, not something since revoked. Record the
request, operator, account/recording/speaker identifiers, reason and result in
the administrator's restricted operational record. These console methods do
not create an authenticated recovery audit event automatically.

## Restore

Choose the retired row within this recording, never through an unscoped global
speaker lookup:

```ruby
speaker = recording.speakers.retired.find(speaker_id)
```

For naming-only recovery, `speaker.restore!` makes the row active without
assigning transcript text or queuing sample learning. Its next remeasurement
will retire it again if it still has no lines.

To return an explicitly identified existing line to this speaker atomically:

```ruby
line = recording.transcript_lines.fetch(line_index)
revision = recording.transcript_revision
# Verify this is exactly the line the requester wants moved.
recording.restore_speaker_line!(
  speaker,
  line: line.fetch(:locator),
  was: line.fetch(:text),
  revision: revision
)
```

Use the line locator and text keys returned by the current model; do not invent
word offsets or alter the revision to bypass a conflict. The recovery and line
edit roll back together on stale input. After success reload the recording,
inspect the intended line and naming, and verify the recovered speaker has no
samples, probe or recognition evidence.

## Recovery limits

Restoring the row alone does not rewrite the transcript or assign any line to
it. Explicit line recovery must use the model's stale-text/revision guards and
is a new transcript edit, visible to people who can currently read the
recording. Neither form restores voice samples, probe embeddings, recognition
confidence or previous review receipts.

If the active-speaker limit is reached, resolve that explicitly rather than
raising the cap or reusing a retired label. A stale line locator requires a
fresh inspection and renewed confirmation of the intended line, not a forced
database write.

This slice does not change transcript replacement's `delete_all`, hard owner
deletion/cascades, voice-name deletion, or resident-owned memory/files. History
is not pruned by a new job. Account exports carry active speakers only; an
export/import is not a backup of retired naming history. Issue #93 remains open
for the broader audit.
