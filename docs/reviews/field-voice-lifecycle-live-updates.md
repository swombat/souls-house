# Field voice lifecycle invalidation — issue #409 B

Backend-only follow-up to the separately owned roster slice A. The approved
scope and Lume's amendment are in issue #409 (comment 6216305443).

## Producers and boundaries

- Enrolment creation, sample attachment, displayed status/sample length/expiry
  changes and destruction refresh the existing recording stream. Old and new
  speaker associations are resolved before destructive writes.
- Print creation, generation/sample-length changes and destruction refresh
  linked recording details and the owning voices' account rosters. Consent
  attribution/date changes are roster-only. Ownership comes from the voice,
  not a potentially stale print account.
- Forget snapshots recognised recording IDs before its bulk clear. Name deletion
  snapshots linked ∪ suggested ∪ recognised IDs before any clear, independently
  of transcript readiness or whether a rerender changes text.
- Print destruction supplies the remembered-state removal marker. A generation
  bump with no print, enrolment or recognition row remains silent.
- `FieldRecordingActivity` is a producer helper, not a new subscribable stream.
  It sends only the existing recording marker. Scoped HTTP responses and
  `SyncChannel`'s account authorization remain authoritative.
- The helper deliberately does **not** touch recordings: doing so under
  `forget!`'s voice lock would invert the account → recording → voice order.
  Forget-all retains separate per-voice transactions. N affected voices may
  produce N account hints (and repeat a recording hint across those commits).
- `reset_all!` is an operator restore/reconnect snapshot, not account-wide live
  fan-out. Its existing sample destruction still runs, with presentation skipped.

Consent checks, storage, sample authorization, dispatch, recognition and locking
policy are unchanged. Refreshes invoke none of them. Clock expiry produces no
new timer or broadcast; the existing sweep's destruction does produce a hint.
Snapshot labels/targeted refresh UI and browser validation are outside this
backend commit.

## Shared behavior and count bounds requiring review

The roster helper now uses the existing `FieldTweetStream` transaction registry
pattern. Producing writes in a transaction coalesce per account and wait for the
outer commit; rollback discards them. The two A assertions that expected two
account markers for a speaker batch or recording destruction now expect one.
No A UI, authorization or producer allowlist was duplicated.

The recording helper coalesces B producers by the same pattern. As in
`FieldTweetStream`, separate committed savepoints can each contribute a marker
after the outer commit. The original recording callbacks and transcript rerender
are untouched: a name deletion that saves a linked recording can also send that
recording's existing refresh in addition to B's explicit bulk-clear hint. Tests
pin this two-marker bound; non-ready recordings still get B's explicit hint.
There is no new account/Field listing fan-out for an enrolment or print.

## Focused evidence

`test/models/field_voice_lifecycle_activity_test.rb` covers rendered and silent
fields, sample attachment, old/new ownership, destruction, write-back/refusal,
bulk paths, generation-only silence, outer/savepoint rollback, transaction count
bounds, restore disposition, no recording writes/locks during forget, and no
vendor/inference work from a refresh.

`test/channels/field_voice_lifecycle_channel_test.rb` covers member/admin access
and outsider/pending/foreign/native/collection denial on recording streams.
Existing roster-channel and human API authorization tests remain applicable.
The stale-preview-after-remote-forget endpoint test in
`test/controllers/field_voices_controller_test.rb` is unchanged.
