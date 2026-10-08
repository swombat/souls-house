# Field recordings: build spec

*Lume, 2026-10-08. Version 2 of PR #202. It replaces the plan Mira reviewed
at `a6e42a3`, and every change she asked for is folded in (list at the end).
Daniel approved the shape in weVzle and asked for a full spec, then Mira's
review, then the build. Mockups: the "Recordings in the Field" Stone in weVzle.*

## 0. What this builds, and in what order

Recordings join files and notes in the Field. You bring in an audio file, the
house transcribes it with speakers separated, you say who each speaker is,
and residents can read the transcript. There is a rolling weekly allowance.

The design idea is unchanged: **nobody enrols a voice up front.** You name
speakers on the transcript in front of you. What changed after Mira's review
is that naming a speaker and *remembering a voice* are now two separate acts,
and remembering a voice (a biometric print) is gated and off by default.

| Slice | What ships | Gate |
|---|---|---|
| **A. Recordings** | Direct upload, allowance, async Scribe transcription with diarization, transcript view, naming speakers per recording, "You", resident read access, the Recordings tab | None. Ships when built and reviewed |
| **B. Suggestions** | "Suggested from what's said" labels with a quoted line as evidence | None |
| **C. Recognition** | pyannote prints, "remember this voice", identify on later recordings, the Voices page, real deletion | House flag `field_voiceprints` **off**, and per account `recognise_voices` **off**. It's built and tested but not switched on until Daniel settles the consent basis (§9) |

Each slice is its own PR, reviewed by Mira before merge. Slice C can be built
in full while its gate stays shut.

## 1. What exists (read from master `6e6e3c7`)

- `FieldFile`: account-scoped, `Discard::Model`, `has_one_attached :file`,
  100 MB cap, `uploaded_by` polymorphic (User or Agent). It accepts **only an
  `UploadedFile` from the same request** (`FieldFile::Upload`), because a
  signed blob id would let someone reattach a blob they once had a URL for.
- `FieldController#index` renders `field/index` with All / Files / Notes;
  `FieldItems.file_json` / `note_json` shape the items.
- `Api::V1::Field::FilesController` gives residents index/show/download/create
  and lets them destroy only their own uploads.
- `Api::App::V1::UploadsController` already does **direct upload safely**:
  `create_before_direct_upload!` with the asker pinned in blob metadata, and
  the consuming endpoint checks that pin. Slice A copies this pattern.
- `ElevenLabsStt`: synchronous Scribe v2, 60 s timeout, no diarization. It is
  left alone. Recordings get their own client.
- `MeteredActionEvent.admit!`: account `with_lock`, window rows, unique
  `request_id`. The allowance borrows its locking shape but gets its own table,
  because its unit is audio seconds, not requests.
- ffprobe and ffmpeg are in the image (`TelegramVideoPreview` shells out via
  `Open3`). Jobs run on Solid Queue.
- Active Record encryption is configured and already used for tokens
  (`ServiceConnection#credential_payload`, `ResidentTurn#payload`).

## 2. Vendors: checked facts and open checks

**ElevenLabs Scribe v2** (`POST /v1/speech-to-text`, checked 2026-10-08):
- File upload under 5 GB, or `cloud_storage_url` under 2 GB.
- `diarize: true`, `num_speakers` (a *maximum*, up to 32),
  `timestamps_granularity: word`. Words come back with `start`, `end`,
  `type` (word / spacing / audio_event) and `speaker_id`.
- `webhook: true` returns 202 early and delivers the result to webhooks
  configured **in the ElevenLabs dashboard** (HMAC auth available, but
  verification is ours to do). `webhook_metadata` (JSON, at most 16 KB) comes
  back in the payload.
- `GET /v1/speech-to-text/transcripts/{id}` and `DELETE …/{id}` exist. The
  202's `transcription_id` is documented as *nullable*, so polling can't be
  the only path.
- `enable_logging: false` (zero retention) is enterprise-only, so ElevenLabs
  keeps the transcript by default. We call DELETE once we've stored our copy.

**pyannoteAI** (checked 2026-10-08):
- `POST /v1/voiceprint` (at most 30 s of one speaker) → a print, billed per
  print. `POST /v1/identify` takes `url`, `voiceprints`, `matching.threshold`
  and `matching.exclusive`, plus `numSpeakers` / `minSpeakers` /
  `maxSpeakers`, `model` (`precision-2` / `precision-3`) and `webhook`. It
  diarizes *and* matches in one job, billed per second, 20 s minimum.
- All scores are 0–100. Identification confidence is always on;
  `turnLevelConfidence` is optional. *Calibration of the identification
  confidence is not documented, so the bands in §7 are starting points
  to measure, not facts.*
- Job output, including generated voiceprints, is deleted 24 h after the job
  ends. Audio fetched from a URL is deleted from the worker right after
  processing. Never used for training. Processing region defaults to "any";
  **EU only is a dashboard setting** (owed: Daniel sets it before C opens).
- STT orchestration (`/diarize` with `transcription: true`) exists, but it
  can't be combined with identification and uses Parakeet/Whisper, not
  Scribe. Not used.

**Owed before slice A is deployed (Daniel):** create the ElevenLabs
speech-to-text webhook pointing at `/webhooks/elevenlabs/stt` with HMAC, and
put its id and secret in credentials (`ai.eleven_labs.stt_webhook_id`,
`ai.eleven_labs.stt_webhook_secret`). **Before C:** a pyannote API key, the
EU processing region, and a read of their DPA. **Price check** (§8) before
the 20 h default is final.

## 3. Data model

### `field_recordings`

| column | notes |
|---|---|
| `account_id` | not null |
| `uploaded_by_type/_id` | polymorphic, as on FieldFile |
| `title`, `note` | same limits as FieldFile |
| `expected_speakers` | int, nullable, 1..32 |
| `duration_ms` | int, from ffprobe, not null once probed |
| `status` | `probing` → `queued` → `transcribing` → `ready`; `rejected` (too long / unreadable, no allowance used); `failed` |
| `failure_reason` | short, human-readable string |
| `attempt_token` | the *current* attempt. Set when a dispatch is claimed, and cleared on any terminal state or discard (§5a) |
| `dispatch_count` | int, at most 3 |
| `transcript_words` | jsonb: `[{s, e, t, spk}]`, ms ints, Scribe words and audio events, exactly as Scribe returned them apart from compaction |
| `transcript_text` | rendered text with names (rebuilt when names change) |
| `language_code` | from Scribe |
| `ready_at` | |
| `discarded_at` | Discard. The recording is discardable like a file |

`has_one_attached :audio`. Index on `[account_id, created_at]`.

### `field_recording_dispatches`

One row per vendor dispatch. This is the record vendor cleanup works from,
and it outlives the attempt it belongs to.

| column | notes |
|---|---|
| `field_recording_id` | |
| `attempt_token` | unique. Written **before** the POST |
| `request_id`, `transcription_id` | nullable. Filled from whichever arrives first, the POST response or the webhook |
| `outcome` | `in_flight` / `succeeded` / `failed` / `superseded` |
| `vendor_deleted_at`, `vendor_delete_error` | cleanup state |

### `field_recording_speakers`

One row per diarized speaker in a recording.

| column | notes |
|---|---|
| `field_recording_id` | |
| `label` | the diarizer's id (`speaker_0`). Unique per recording |
| `talk_ms` | total speech in this recording |
| `clip_start_ms`, `clip_end_ms` | a ≤ 5 s stretch of the speaker alone, for the "listen" button |
| `field_voice_id` | nullable. Set **only by a human naming act** (or confirming a suggestion/guess) |
| `naming_source` | `human` / `confirmed_suggestion` / `confirmed_recognition`, nullable |
| `named_by_type/_id` | who named it |
| `suggested_voice_id`, `suggested_name`, `suggestion_quote`, `suggestion_quote_ms`, `suggestion_source` | slice B. Never shown as a name, only as a suggestion |
| `recognised_voice_id`, `recognition_confidence`, `recognition_print_generation` | slice C. A recognition is a *guess* until a human confirms it |

A speaker shows as: the name of `field_voice_id` if set; otherwise
"Speaker N". Suggestions and recognitions render as chips beside it, never in
its place (§7).

### `field_voices`

An account-scoped identity that a name refers to. **Print-optional.**

| column | notes |
|---|---|
| `account_id` | |
| `name` | as typed. Unique per account, case-insensitive, among kept voices |
| `user_id` | nullable. Set when the voice is the uploader saying "this is me", or explicitly linked to an account member. Never by name equality |
| `created_by_type/_id` | |
| `print_generation` | bigint, default 0. **Monotonic and never reset.** Bumped by every print write *and* every forget. Lives on the surviving row, so forget → re-enrol can never reproduce an old generation |
| `discarded_at` | an *identity* (a name) follows the discard rule. Its print doesn't (below) |

Linking two speakers to one voice is always explicit: the chip offers
existing voices by name, and picking one links. Typing a new name that
matches an existing voice asks "Same Priya as in *Board call*?" instead of
merging silently.

### `field_voiceprints` (slice C only)

| column | notes |
|---|---|
| `field_voice_id` | unique. At most one print per voice |
| `account_id` | denormalised so every query can scope by account without a join |
| `print` | **encrypted** (`encrypts :print`, non-deterministic) |
| `generation` | copied from `field_voices.print_generation` when written. A print is current only while the two are equal |
| `sample_recording_id`, `sample_ms` | where the sample came from, and how much clean speech it had |
| `consented_by_type/_id`, `consented_at`, `consent_text_version` | who ticked "remember this voice", and what it said |
| `vendor` | `pyannote` |

Prints live in their own table so that forgetting can destroy the row without
touching the voice's name history, and so that nothing which serialises
`FieldVoice` can reach a print.

### `field_recording_reservations` (the allowance ledger)

| column | notes |
|---|---|
| `account_id` | |
| `field_recording_id` | **unique**. One reservation per recording, ever |
| `audio_ms` | reserved amount |
| `state` | `pending` → `consumed`, or `pending` → `released` |
| `reserved_at`, `consumed_at`, `released_at`, `release_reason` | |

### Account

- `recording_ms_weekly_limit` (bigint, default 72_000_000, i.e. 20 h). Per
  account, so Daniel can change it from the console without a deploy.
- `recognise_voices` (boolean, default **false**). Slice C, and only
  meaningful when the house flag is on.

## 4. Upload (slice A)

Recordings can be hours long, so the browser uploads straight to storage.
That needs a blob before the recording exists, and the Field's rule is that it
never accepts a bare signed blob id. The pattern from
`Api::App::V1::UploadsController` resolves this:

1. `POST /accounts/:id/field/recordings/uploads` with `filename`,
   `content_type` (must start with `audio/` or `video/`), `byte_size`
   (≤ `FieldRecording::MAX_BYTES` = 2 GB, which matches Scribe's URL limit)
   and `checksum`. The server creates the blob with metadata
   `{"field_recording_upload": {"user_id", "account_id", "expires_at"}}` and
   returns the direct-upload URL and headers.
2. The browser PUTs the bytes and shows progress.
3. `POST /accounts/:id/field/recordings` with `upload_id` (the signed id),
   `title`, `note` and `expected_speakers`. **Claim, atomically:** in one
   transaction, `SELECT … FOR UPDATE` the blob row, then check that its
   metadata names **this user and this account**, that `expires_at` (6 h)
   hasn't passed, and that no `active_storage_attachments` row references it;
   then create the recording and its attachment, and commit. A second create
   racing for the same blob waits on the row lock and then sees the
   attachment. Any failure is a 422 that says nothing about the blob.
4. The recording is created in `probing` and `FieldRecordings::ProbeJob` runs.

**Probe.** `ffprobe` on a download of the blob reads the duration and
confirms there's an audio stream. Unreadable → `rejected` ("This file has no
audio we can read"). This happens after the upload, because the server can't
see the bytes before then. To spare people a 2 GB upload that will be
refused, the browser reads the duration first (`<audio>` metadata on the
local file) and shows the allowance verdict before uploading. That is
advisory only. The server's probe decides.

**Cleanup.** `FieldRecordings::OrphanSweepJob` (hourly, in `recurring.yml`)
purges blobs carrying `field_recording_upload` metadata that are unattached
past `expires_at`. It takes the same blob row lock and rechecks "no
attachment" before purging, so a claim and a purge can't both win. It also
purges the audio of `rejected` recordings after 24 h.
A rejected recording isn't something anyone brought into the Field, so the
discard rule doesn't apply to it.

Residents do **not** upload recordings in slice A. The resident Field API
stays files-only for writes.

**Retry** ("Try again" on a failed recording) is an internal path, not the
upload endpoint. `FieldRecording#retry!` creates a new recording whose audio
attachment points at the *same blob*, under the old recording's lock, and only
if the old one is `failed` and kept. The new recording goes through probe and
reservation like any other. The upload endpoint's "unattached" rule stays
strict.

## 5. Transcription (slice A)

Every step below runs under the lifecycle contract in §5a.

`FieldRecordings::TranscribeJob(recording_id)`:

1. **Claim** (recording lock): continue only if the recording is kept,
   `queued` and `dispatch_count < 3`. Set `transcribing`, mint
   `attempt_token`, bump `dispatch_count`, and insert the dispatch row
   (`in_flight`). Commit. The job holds the minted token as `my_attempt`.
2. POST to Scribe (outside any lock): `model_id=scribe_v2`, `diarize=true`,
   `timestamps_granularity=word`, `tag_audio_events=true`,
   `num_speakers=expected_speakers` when given, `webhook=true`,
   `webhook_id`, and
   `webhook_metadata={"recording": <obfuscated id>, "attempt": attempt_token}`.
   The file goes as `cloud_storage_url`: a signed blob URL valid for 6 h.
   With local storage in development, the file is posted as multipart.
3. **Record the response** (recording lock): always write `request_id` and
   `transcription_id` onto *my* dispatch row, whatever state the recording
   is in now, because cleanup needs them. Touch the recording only if its
   `attempt_token == my_attempt` and it's still `transcribing`.

`POST /webhooks/elevenlabs/stt` (no session, CSRF skipped):

1. Verify the HMAC signature against `stt_webhook_secret`, with a timestamp
   tolerance of 5 min. If it fails: 401, nothing touched.
2. Find the **dispatch row** by the echoed `attempt`. If there is none,
   return 200 and do nothing. Under the recording lock, write the payload's
   `transcription_id` (and `request_id`) onto the dispatch row if they're
   missing. That covers a webhook that arrives before the POST response.
3. Still under that lock, the result is **accepted** only if the recording
   is kept, `transcribing`, and its `attempt_token` equals this attempt.
   If accepted, in the same transaction: store the words, create the speaker
   rows (talk time, clip choice: the longest turn of that speaker with no
   other speaker within 1 s, trimmed to 5 s), render `transcript_text`, set
   `ready`, clear `attempt_token`, mark the dispatch `succeeded`, and
   **consume the reservation** (§6). If not accepted, mark the dispatch
   `superseded` and store none of its content.
4. After commit, **in both cases**: enqueue
   `DeleteVendorTranscriptJob(dispatch_id)`. If accepted, also broadcast,
   and in slice B enqueue suggestions.

`DeleteVendorTranscriptJob` calls Scribe's DELETE with the dispatch's
`transcription_id`, retrying up to 3 times, and records
`vendor_deleted_at` or the error (never content). **If no
`transcription_id` ever arrives** (neither the POST response nor the webhook
carries one, and the docs mark both nullable), we can't delete. The
transcript then stays in the house's ElevenLabs history under their retention
policy. The dispatch row records `vendor_delete_error: "no transcription id"`,
and the Field's "about recordings" note says vendor deletion is attempted,
not guaranteed. The first live call checks which source carries the id, and
its result goes into this section.

**When no webhook arrives.** `FieldRecordings::StuckSweepJob` (every 10 min)
looks at `transcribing` recordings whose current dispatch is older than
`max(20 min, 0.5 × duration)`. If that dispatch has a `transcription_id`, it
GETs the transcript and hands it to the same accept method as the webhook,
with the same attempt guard. Otherwise, or if the GET fails, it **abandons
the attempt** under the lock: the dispatch becomes `failed`,
`attempt_token` is cleared, and the recording goes back to `queued` if
`dispatch_count < 3`, or to `failed` (with release) if not. A webhook that
arrives later for the abandoned attempt is `superseded`: its content is
ignored, but it is still deleted at the vendor. The per-recording cap of 3
bounds one recording's attempts; the account-wide exposure bound below bounds
spend across recordings and retries.

**Account-wide dispatch exposure (added in build, Mira on #212).** Refunded
failures must not buy unbounded vendor work, so dispatching has its own
bound, independent of the allowance. Every committed dispatch records the
audio it sent (`field_recording_dispatches.audio_ms`). A claim, taken under
the account lock and then the recording lock, refuses to send if the audio
already sent for this account in the last 7 days plus this recording would
exceed **2 × the weekly allowance**. Every attempt counts, whatever became of
it, because a timed-out or failed attempt may still have been billed. A
refused claim fails the recording with "This Field has sent as much audio to
the transcriber as it can this week" and releases its reservation. "Try
again" later goes through the same check. `dispatch_count` counts attempts
we *committed* to sending. It isn't proof the vendor received or billed
them, which is why the bound is deliberately conservative.

**Fail closed on configuration.** Nothing is sent unless the API key, the
webhook id and the webhook secret are all configured: without them a result
could not come back verifiably. A recording then waits in `queued` and no
attempt is used. The sweep doesn't re-send queued recordings while
configuration is missing.

The same sweep **settles stranded reservations** after a crash: a `pending`
reservation on a `rejected` or `failed` recording is released; on a discarded
one it settles by the discard rule below. A `queued` recording with no live
job for 30 min is re-enqueued; claiming it still respects both bounds.

**Errors at dispatch** (only for `my_attempt`, under the lock, guarded as in
step 3): a 4xx other than 429 → `failed`, with our own wording and the status
code (vendor text is never stored or logged), and the reservation released.
A 429, a 5xx or a transport error → the dispatch is
`failed`, `attempt_token` is cleared, and the recording goes back to
`queued` with a backoff (1, 5, 15 min), or to `failed` once the cap is
reached. A late error for an attempt that's no longer current changes
nothing on the recording.

**Discarding a recording** (amended in build; accepted by Mira on #210).
Under the recording lock: discard, clear `attempt_token`, and settle the
reservation. **If nothing was ever dispatched, it is released. Once a
dispatch has been committed, it is consumed**, because the vendor work may
already be paid for, and otherwise upload → discard → repeat would buy
unbounded transcription. A reservation already consumed stays consumed.
Everything still in flight then fails its attempt guard. The page says so
before deleting: "Deleting a recording that has started transcribing
doesn't give its minutes back."

## 5a. The lifecycle contract

One rule covers probe, dispatch, response, webhook, sweep, discard and retry:

- **Every state change happens under the recording's row lock** and rechecks,
  inside that lock, the conditions it was started under: kept, the expected
  `status`, and (for anything attempt-bound) `attempt_token == my_attempt`.
  If any of them fails, the step changes nothing on the recording. Its only
  allowed effect is recording vendor ids on its own dispatch row and
  queueing vendor cleanup.
- **Terminal states** (`ready`, `rejected`, `failed`, discarded) clear
  `attempt_token`, so no stale worker can move a recording out of one.
  Nothing moves a recording from `ready` back to `queued` or `failed`.
- **Lock order:** account, then recording, then (in slice C) voices in id
  order. Probe's admission takes account → recording. Consume and release
  take only the recording lock and a guarded `UPDATE … WHERE state =
  'pending'`. They never need the account lock, because they only ever lower
  "used" or keep it the same, so they can't break an admission decision.
- **Probe** rechecks under account → recording that the recording is kept
  and still `probing` before it reserves. A recording discarded while
  ffprobe ran gets no reservation.

## 6. The allowance (slice A)

**Unit:** audio milliseconds. **Window:** rolling 7 days. **Limit:**
`account.recording_ms_weekly_limit`.

**Used** = sum of `audio_ms` over reservations where
`state = 'pending'` (**at any age**) **or**
`(state = 'consumed' AND consumed_at > now - 7 days)`.

Consumed minutes count from the moment transcription *finished*, not from
upload. That's the clock that decides when room frees up.

**Reserve** (end of ProbeJob):

```ruby
account.with_lock do
  recording.lock!                                  # lock order: account, then recording
  return unless recording.kept? && recording.probing?   # discarded while probing → no reservation
  return if recording.reservation.present?        # idempotent retry
  used = FieldRecordingReservation.used_ms(account, now)
  if used + duration_ms > account.recording_ms_weekly_limit
    recording.update!(status: "rejected", failure_reason: ...)
    # The audio is purged by the orphan sweep.
  else
    recording.create_reservation!(account:, audio_ms: duration_ms, state: "pending", reserved_at: now)
    recording.update!(status: "queued")
    TranscribeJob.perform_later(recording.id)   # after commit
  end
end
```

The account row lock serialises two uploads finishing their probe together.
The unique index on `field_recording_id` makes a second reservation for the
same recording impossible, even outside the lock.

**Transitions**, each guarded by `WHERE state = 'pending'` so that a
duplicate does nothing:
- **consume**: on an accepted transcript (§5 step 3). Exactly once. Later
  failures (suggestions, recognition) never refund it.
- **release**: on `failed` or `rejected`, on discard before any dispatch, or
  by the sweep for a stranded reservation. Discard after a dispatch consumes
  instead (§5). A released recording can't be re-queued;
  "Try again" is `retry!` (§4), with a new recording and a new reservation.

**What people see.**
- The gauge in the Recordings tab: "3 h 20 m of 20 h used in the last 7
  days". Pending reservations are included and marked "(1 h 10 m still
  transcribing)".
- Over the limit: "This recording is 2 h 05 m. You have 1 h 40 m left this
  week. Room frees up gradually; enough for this one by about Tue 14 Oct,
  09:10." That time is computed from consumed rows only and labelled
  "about". If consumed rows expiring could never make enough room, because
  pending work alone fills the gap, it says "No estimate yet: other
  recordings are still transcribing" instead of inventing a date.
- No upsell wording. If an account needs more, Daniel raises the limit.

## 7. The transcript and naming (slice A; chips from B and C)

**Transcript view** (`field/recordings/show`, a page of its own rather than
the side panel, because transcripts are long):

- The audio player is at the top. Clicking a word seeks to it.
- Turns: consecutive words with the same `spk`, with breaks at gaps over
  1.5 s. Each turn shows the speaker's display name and a timestamp.
- Words whose speaker is uncertain are **not reassigned**. In slice A
  Scribe's own label is the only label. In slice C, see "Diarization when
  both run" below.

**The speaker strip** (above the transcript, one card per speaker): display
name or "Speaker N", talk time, a play button that plays the 5 s clip (the
media fragment `#t=start,end` on the audio, so no extra file is cut), and
the chip.

**The chip ("Who's this?")** opens a small popover:
1. **You** (always first, with the current user's name): links to the
   user's own voice (`user_id` = them), creating it if needed.
2. Existing voices in this account, most recently named first.
3. Account members who have no voice yet.
4. A text field: "Someone else…"

Naming sets `field_voice_id` **on this speaker only**. It never renames other
recordings. Renaming a *voice* (from the Voices page, slice C, or a small
"rename" on the voice) is a separate, explicit act that does change every
place that voice appears. That's the point of linking.

**Un-naming** clears `field_voice_id`, and the speaker goes back to
"Speaker N".

**"Which one is you?"** is no longer a prediction. Instead, the first time a
user opens a ready transcript they uploaded, and they have no voice linked to
their user, the strip shows one line: "Is one of these you? Tap *You* on
their card." It's dismissible and stored per user, and it never comes back
once they have a voice. No biometrics are needed to ask it.

**Suggestion chips (slice B)** render beside the speaker in a dashed outline:
"Priya? — says 'my venue contract' (04:12)". Tapping the quote seeks to it.
**Confirm** names the speaker with `naming_source: confirmed_suggestion`.
**✕** clears the suggestion. The label reads **"Suggested from what's
said"**, never a resident's name. An "Ask Wren" button that actually wakes the
resident is a later slice, not in this spec.

**Recognition chips (slice C)** look the same, with a different source line:
"Tomás? — sounds like the Tomás this Field remembers (82)". Confirm and ✕ work
the same way. There is **no solid auto-label**: v1 recognition only ever
guesses, and a human confirms. The "≥ 75 solid" band from the plan is
dropped until we've measured the confidence scale against real recordings.
Below the identify threshold, nothing is shown.

**Residents.** `GET /api/v1/field/recordings` and `/:id` return title, note,
status, duration, uploader, `transcript_text` (with display names; unnamed
speakers as "Speaker N"), and speakers as `{label, name, talk_ms}`. No
suggestions, no recognitions, no confidences, no voice ids, never a print.
Residents read; they don't name in this spec. (The plan's "residents may
suggest" is deferred: a resident suggestion would have to be labelled as the
resident's, and that belongs with "Ask Wren".)

**`transcript_text` and inferred names.** The rendered text uses **only
human-set names** (`field_voice_id`). Suggestions and recognitions never
reach `transcript_text`, the API or a resident. This answers Mira's point
that inferred names aren't the user's words: an inferred name never becomes
text anywhere until a human confirms it, and then it is the user's word.

## 8. Suggestions (slice B)

`FieldRecordings::SuggestSpeakersJob(recording_id)`, enqueued after `ready`:

- Input: up to 32 k characters of `transcript_text` with speakers as
  `[S0]`, `[S1]`, …; the title and note; the names of the account's voices
  and members.
- Model: `UtilityInference.classify` with a small model, house key, JSON
  output `[{label, name, quote, at_ms}]`.
- **Validation is ours, not the model's.** A suggestion is kept only if the
  quote appears verbatim in that speaker's words (after whitespace
  normalisation), `at_ms` falls inside one of their turns, and the name is
  one of the account's voices or members, or a name that appears in the
  title, the note or the transcript. Anything else is dropped. A speaker
  that already has a human name gets no suggestion.
- A failure here does nothing visible and refunds nothing.

**As built (Mira on #215).**
- **Gated in production.** Nothing is sent unless `SOULSHOUSE_FIELD_SUGGESTIONS=on`
  in deploy configuration. Off means no job is queued and no inference is
  contacted.
- **What is sent, and where.** Up to 20,000 characters of the transcript, with
  speakers as S1, S2…; the recording's title and note; and at most 50 names
  (this Field's voices and members). It goes through OpenRouter to Google
  Gemini 2.5 Flash, on the house key, via `UtilityInference.structured`.
  Provider routing isn't pinned, and OpenRouter's and Google's retention and
  training terms for this traffic **are to be verified before the gate is
  turned on**. That verification is the precondition, not the code.
- **Told to people where it happens.** When the gate is on, the upload dialog
  and the transcript page say in plain words that the transcript, title and
  note are sent to Google Gemini through OpenRouter to suggest names.
- **One call per recording**, claimed durably under the recording lock before
  it is made. Duplicate jobs and retries after an empty or failed answer never
  call again.
- **Only untouched speakers.** A speaker someone has named, un-named or
  dismissed a suggestion for is never suggested again. Every such decision
  moves the speaker's `decision_generation` on. A suggestion records the
  generation it was made against, and a confirm or dismiss must send the
  generation it showed. Anything stale is refused.
- **Names match whole words**, and a name that normalises to nothing never
  matches. **The quote shown is the speaker's own words**, recovered from the
  matched source, with its true time, not the model's rendering of it.
- **Confirming always goes through the "same Priya?" check** when the
  suggested name matches a known voice, exactly like a typed name.

**Cost note.** I haven't priced Scribe-with-diarization per hour, or pyannote
identify, from their current pages. Both need checking before the 20 h
default is final. Suggestions are one small call per recording.

## 9. Recognition (slice C, gated)

### The gate

Recognition does anything at all only when **both** the house flag
`field_voiceprints` (an env var in deploy config, default off; see
"Restoring") **and** `account.recognise_voices`
(default off) are on. When either is off:
- no "remember this voice" box,
- no print is built, replaced or sent,
- no identify call is made,
- the Voices page shows names only, plus "Voice recognition is off".

Turning `recognise_voices` off leaves stored prints in place but unused. The
setting's copy says so and offers "Forget all voices" beside it.

**Open, for Daniel and someone who knows the law:** the lawful basis for
storing a print of someone who isn't an account member (Art. 9: explicit
consent from *that person*, which "she'd be fine with it" isn't). Until
that's settled, the house flag stays off in production. The "Remember this
voice" box below records *who said* the person agreed. That is an
attestation, not the person's own consent, and it doesn't settle the basis
by itself. Opening the gate needs the legal basis plus a consent-evidence and
revocation flow that the person themself can use. That flow is out of scope
for this spec and comes back to Daniel when the basis is known. Slice A and B don't
depend on it.

**As built.** The house gate is `SOULSHOUSE_FIELD_VOICEPRINTS=on`, **and**
`SOULSHOUSE_BACKUP_RETENTION_DAYS=<n>`, **and** a pyannote key in
credentials (`ai.pyannote.api_key`). All three live outside the database. The
retention requirement is enforced in code, so the precondition can't be skipped
by turning the flag on alone, and the number it gives is what the Voices page
tells people. The account gate is `accounts.recognise_voices`. Only someone
who can manage the account changes it, under the account lock that identify
and print write-back also take. "Forget voice", "Forget all voices", deleting
a name and the restore reset (`bin/rails field:reset_biometrics_after_restore`)
are never gated. The **Voices page** (`/field/voices`) lists every name, says
what is remembered (sample length, by whom, when), and carries the setting,
the forget actions and the "What this means" text.

### Remembering a voice is its own act

When the gate is open, the naming popover gets one extra line under the
chosen name:

> ☐ **Remember Priya's voice** so this Field can suggest her in later
> recordings. *Only tick this if Priya has agreed.* [What this means]

It's unticked by default, every time. For **You**, the line reads "Remember
my voice", and the consenter is the person themself. Ticking creates the
consent fields on the print, and the print job runs. Naming without ticking
is just naming: no biometric processing happens.

The house never builds a print as a side effect: not when naming, not when
confirming a recognition, not retrospectively for voices named before slice C
was switched on.

### One synchronisation rule for prints

Every operation that reads or writes a print, or acts on a recognition,
takes the **voice row lock** (after the recording lock, if it needs both;
voices in id order). Forget, build write-back, identify write-back and
confirming a recognition all serialise on that lock. Under it, each one
rechecks:
- **the gate** (house flag and `recognise_voices`),
- the voice is kept, and the recording too, where one is involved,
- **the generation**: the voice's current `print_generation` equals the
  generation the operation started from,
- and, for builds, that the consent token still exists.

These checks run **twice**: immediately before any vendor dispatch, and again
at write-back. If any check fails at dispatch, nothing is sent. If any fails
at write-back, the result is thrown away. A request already dispatched can't
be recalled. pyannote deletes the job input after processing and the output
after 24 h, and that's all we can say about it.

Because `print_generation` lives on the voice and only ever goes up (bumped
by every write *and* every forget), an old snapshot can never match a print
enrolled after a forget.

### Building the print

`FieldVoices::BuildPrintJob(speaker_id, consent_token)`. The job records
`start_generation = voice.print_generation` when the consent token is made.

1. Run the rechecks above. Any failure: stop and delete the token.
2. **Choose the sample.** Turns of this speaker with no other speaker within
   1 s, longest first, joined until 30 s. If there's less than 8 s → stop,
   and say "Not enough clear speech from Priya in this recording to remember
   her voice. It'll offer again on a later recording." If `expected_speakers`
   was given and Scribe found fewer speakers → stop with "Fewer voices than
   expected; Priya may be merged with someone." The count guard and the
   clean-turn guard **reduce** the risk of a merged speaker. They don't prove
   one person, which is why step 3 exists.
3. **Preview.** The sample is cut (ffmpeg, to a temporary blob that expires
   in 1 h) and the popover plays it: "This is what will be remembered as
   Priya. [Use it] [Not her]." Only **Use it** continues. **Not her**
   deletes the sample and the consent token.
4. **Dispatch.** Under the voice lock, run the rechecks; then send the sample
   to pyannote `/voiceprint` via a 1 h signed URL. Poll the job (webhook
   optional, later).
5. **Write back**, under the voice lock: run the rechecks *again*. If any
   fails, throw the result away and delete the sample and token. Otherwise
   bump `voice.print_generation`, upsert the print with that generation, and
   delete the temporary sample blob and the consent token.

**Replacing a print** happens only by the same explicit act on a later
recording ("Remember Priya's voice from this recording instead"), offered
when this speaker has more clean speech than the stored `sample_ms`. It's the
same job with a new consent row.

### Identifying

`FieldRecordings::IdentifyJob(recording_id)`, after `ready`, when the gate is
open and the account has at least one print:

1. Snapshot `{voice_id → print_generation}` for every current print in the
   account, under each voice's lock, with the rechecks. Dispatch `/identify`
   with the audio URL, those prints (labelled by an opaque per-job key, never
   the name), `matching.exclusive: true`,
   `matching.threshold` (start at 50, a tunable constant),
   `numSpeakers`/`maxSpeakers` from `expected_speakers`, and model
   `precision-2`.
2. Poll. On completion, take the recording lock, then the matched voices'
   locks in id order, and run the rechecks. Any match whose voice fails
   (generation moved, forgotten, gate shut, voice discarded) is thrown away.
   Store each surviving recognition with its `recognition_print_generation`.
3. **Diarization when both run (Mira's B, provisionally; an experiment, not
   a calibration).** Scribe's words and speakers stay as they are. Work only
   on **non-overlapping speech**: drop any interval where identify reports
   more than one segment, or where Scribe words from two speakers overlap,
   so crosstalk and duplicated segments can't inflate coverage. For each
   Scribe speaker, if at least 70% of their remaining word time lies in
   segments matched to one voice, and none of it lies in a segment matched to
   another voice, record a *recognition* (`recognised_voice_id`, confidence
   = time-weighted mean). Otherwise there's no recognition. Speech that's
   uncovered or ambiguous stays visible as it is: "Speaker N" with no chip,
   and nothing reassigned. If both diarizers' turns were adopted, we'd be
   choosing a truth; this way we only ever add a guess on top of the user's
   view.
4. Speakers already named by a human aren't touched. A recognition never
   sets `field_voice_id`.
5. Don't refund: identify failing leaves the transcription consumed.

Rerunning identify (a button on the recording, or after the Voices page
changes) replaces recognitions only. Human names and confirmations stay.

**Confirming a recognition** takes the recording lock, then the voice lock,
and runs the rechecks plus one more: `recognition_print_generation` must
equal the voice's current `print_generation`. A chip left over from before a
forget or a replace is rejected ("This suggestion is out of date") and
cleared.

### Forgetting

**"Forget Priya's voice"** (Voices page, any account member):

1. Under the voice lock, in one transaction: bump
   `voice.print_generation`, **destroy** the `field_voiceprints` row, delete
   any pending consent tokens and temporary samples for that voice, and clear
   `recognised_voice_id` / `recognition_*` on every speaker that points at
   it.
2. The name and the human labels stay. They're the account's own words about
   who spoke, and forgetting the *voice* doesn't rewrite the transcripts.
   The Voices page says so: "Priya's name stays on transcripts where someone
   named her. To remove those, rename or un-name them."
3. Because every other print operation rechecks the generation under the
   same lock, nothing queued or in flight can recreate this print, use it, or
   confirm a guess made from it, even if Priya's voice is enrolled again
   afterwards. What has already been sent can't be recalled (above).
4. **"Forget all voices"** does this for every print in the account.

**Deleting a voice** (the name itself) is a separate act. It discards the
`field_voices` row, forgets its print first, and un-names its speakers back
to "Speaker N".

**What forgetting can't do**, stated on the Voices page under "What this
means":
- A print already sent to pyannote in an identify request can't be unsent.
  pyannote deletes job inputs right after processing, and job outputs after
  24 h.
- Database backups taken before the forget still contain the encrypted print
  until they're deleted. `DatabaseBackupJob` uploads `pg_dump`s to S3 and
  expires nothing itself. Any retention would be an S3 lifecycle rule I can't
  see from here. **Precondition for opening the C gate:** Daniel confirms
  (or sets) a backup retention period, and the "What this means" text states
  it as a number of days. "Until backups age out" isn't stated anywhere
  unless they actually do.

**Restoring a database resets biometric state.** A same-database forget log
would be rolled back by the very restore it was meant to survive, so there
isn't one. Instead, the restore runbook has one required step, run before
workers or recognition resume:
`bin/rails field:reset_biometrics_after_restore`. It destroys every print,
bumps every voice's `print_generation`, and deletes all pending consent
tokens, temporary samples and recognition guesses. Manual names stay. Anyone
who wants recognition back re-enrols with a fresh tick. A backstop stored in
the database would be restored along with everything else, so the backstop
lives outside it: the house flag `field_voiceprints` is **deploy
configuration (an env var), not a database setting**. The runbook order is:
flag off, restore, reset task, flag back on. A restored database can't
switch recognition back on by itself.

**Deleting recordings** stays separate. Discarding a recording follows the
discard rule, as for files. It isn't "forget my voice", and the page that
offers one doesn't pretend to be the other.

### Encryption and exposure

- `encrypts :print` with the app's Active Record encryption keys. This is a
  baseline against database-only leaks. It doesn't protect against a
  compromised app holding the key, and it isn't erasure from backups. A
  dedicated key isn't added, because no requirement it would meet has been
  named.
- Prints are filtered from logs (`filter_parameters += [:print]`), never put
  in job arguments (jobs carry ids), never in error reports (the vendor
  client raises with status codes only), never in Inertia props or any JSON.
- `FieldVoiceprint` has no `as_json` / serializer. A test walks every Field
  endpoint (web, resident API, app API) as a member and as a resident, and
  asserts that neither the print bytes nor the key `print` appear.

## 10. Routes

```
# web (members)
GET    /accounts/:account_id/field/recordings/:id              recordings#show
POST   /accounts/:account_id/field/recordings/uploads          recording_uploads#create
POST   /accounts/:account_id/field/recordings                  recordings#create
PATCH  /accounts/:account_id/field/recordings/:id              recordings#update (title/note)
DELETE /accounts/:account_id/field/recordings/:id              recordings#destroy (discard)
POST   /accounts/:account_id/field/recordings/:id/retry        recordings#retry (new recording, same blob)
PATCH  /accounts/:account_id/field/recording_speakers/:id      recording_speakers#update (name / un-name / confirm / dismiss)
GET    /accounts/:account_id/field/voices                      voices#index            (C)
PATCH  /accounts/:account_id/field/voices/:id                  voices#update (rename)  (C)
DELETE /accounts/:account_id/field/voices/:id                  voices#destroy          (C)
DELETE /accounts/:account_id/field/voices/:id/print            voiceprints#destroy (forget) (C)
POST   /accounts/:account_id/field/recording_speakers/:id/print voiceprints#create (preview → use) (C)

# resident API (home account only, like files)
GET    /api/v1/field/recordings
GET    /api/v1/field/recordings/:id

# vendor
POST   /webhooks/elevenlabs/stt
```

The Field index gets a **Recordings** tab, and recordings join **All** as
items (`FieldItems.recording_json`: title, status, duration, speaker names,
uploader). Status changes broadcast on the account channel as files do.

## 11. Tests that carry the weight

**Slice A**
- Upload: a blob made for another user or account, an expired blob, an
  already-attached blob, and a raw signed id from a message are all refused.
- Allowance: two probes finishing at once can't both fit when only one fits
  (threaded test on the account lock). Pending reservations count at any age.
  Consumed ones count for 7 days from `consumed_at`. Consume and release are
  each idempotent. Release after consume does nothing.
- Webhook: bad HMAC → 401. A duplicate delivery → one transcript, one
  consume. A stale `attempt` after a retry is ignored. A webhook for a
  discarded recording consumes nothing new.
- **Races, run concurrently and not just in sequence:** a webhook arriving
  before the POST response (the id lands on the dispatch row, and the
  response then doesn't overwrite a newer attempt); a late POST error after
  the sweep re-queued (no change); discard racing an accepted webhook
  (exactly one wins, and the reservation ends consumed or released, never
  both); discard during probe (no reservation); two creates claiming one
  blob, and a claim racing the orphan purge (exactly one wins).
- Stale and discarded successes still enqueue vendor DELETE, with the id
  taken from either source. With no id from either, the dispatch records the
  limitation.
- The stuck sweep caps at 3 dispatches, then fails and releases. It also
  releases stranded pending reservations on discarded, failed or rejected
  recordings, and re-enqueues orphaned `queued` ones.
- No `ready` recording ever moves back to `queued` or `failed`.
- The over-limit message shows "No estimate yet" when pending work alone
  blocks.
- Naming one speaker never changes another recording. Un-naming restores
  "Speaker N". `transcript_text` changes only on human naming.
- Resident API: a recording in another account is a 404, and there are no
  suggestions or recognitions in the payload.
- The Scribe DELETE is attempted after storing, and its failure is logged
  without content.

**Slice B**
- A suggestion whose quote isn't in that speaker's words, or whose name
  appears nowhere, is dropped. A named speaker gets none. Suggestions never
  reach `transcript_text` or the API.

**Slice C**
- With the gate off (each half separately): no box, no print job, no
  identify, nothing sent to the vendor client (a stubbed client that raises
  if called).
- Naming without ticking creates no print. Confirming a recognition creates
  no print. Switching the gate on creates no prints for existing voices.
- Under 8 s, or fewer speakers than expected → no print, with the right
  message.
- Forget between dispatch and write-back → the result is discarded and no
  row exists. A late identify result for a forgotten or replaced voice →
  that match is ignored.
- **Forget → re-enrol → old result:** a build or identify result started
  before the forget is rejected even though a new print now exists, because
  the generations differ.
- Forget racing a build write-back, and forget racing a confirmation (run
  concurrently): no print survives a forget that committed first, and a
  stale chip can't be confirmed.
- Gate switched off mid-flight: nothing is written back or confirmed.
- `field:reset_biometrics_after_restore` leaves no prints, tokens, samples
  or guesses, keeps manual names, and bumps every generation.
- Cross-account: a voice, print or speaker from account A can't be read,
  named to, forgotten or sent in an identify request from account B.
- Serialiser sweep: no print in any JSON (§9).
- Overlap fixture: Scribe and identify disagree on a stretch → no
  recognition for that speaker, and no word reassigned.

## 12. Build order and review

1. **PR A1a, foundation**: models and migrations, the allowance ledger,
   upload and atomic claim, probe and admission, discard and retry, the
   orphan sweep.
2. **PR A1b, vendor lifecycle**: the Scribe client, dispatches, webhook,
   stuck/settlement sweep and vendor DELETE.
3. **PR A2**: the recording page, the speaker strip, naming, the "You"
   prompt, the gauge, the resident API.
4. **PR B**: suggestions.
5. **PR C**: recognition behind the gate.

Each PR goes to Mira for review, and merges after her approval and green CI
on the exact head (standing rule). Deploying stays Daniel's call. Daniel's
setup steps in §2 are listed in each PR that needs them.

## 13. What changed from the reviewed plan (`a6e42a3`)

- Recognition is **off by default**, behind a house flag as well, and the
  flag stays off until the consent basis is settled. (Mira: consent.)
- Naming and remembering a voice are separate. Remembering is an unticked,
  explicit, per-person box with a preview of the sample and a "Not her" exit.
  No print is ever built as a side effect. (Mira: consent, phase 1.)
- Forgetting destroys the print row. Generation and consent-token guards
  stop queued or late jobs recreating or using a print. Vendor and backup
  limits are stated, and a restore resets biometric state (round two, §14).
  "Forget voice" is separate from deleting recordings and from deleting a
  name. (Mira: forgetting.)
- Inferred names never become text: only human-set names render into
  transcripts or reach residents. (Mira: "inferred names aren't the user's
  words".)
- Diarization: Scribe's words and speakers are preserved, identify only adds
  a guess when overlap is unambiguous, overlap stays unattributed, and there
  are no solid auto-labels until the confidence scale is measured. (Mira: B,
  provisionally.)
- FieldVoice is reused as a print-optional identity. Prints moved to their
  own table. Linking is explicit, never by name equality. Local corrections
  don't rename across recordings. (Mira: phase 1.)
- Allowance: an account-locked reserve, a unique reservation per recording,
  pending counted at any age, `consumed_at` as the clock, idempotent
  guarded transitions, no refund after a successful transcription, a
  dispatch cap that bounds vendor spend, rejection after upload with an
  advisory client preflight, an orphan sweep, and "about" on the free-up
  time. (Mira and the Sol helper: allowance.)
- "Which one is you?" is the post-transcript **You** option plus a one-time
  hint, with no biometric bootstrapping. (Mira.)
- Encryption is described honestly: a baseline, plus log, job-argument and
  error filtering, and cross-account tests. (Mira: encryption.)
- New from checking the vendors: the Scribe webhook needs dashboard setup;
  `transcription_id` may be absent, hence the sweep design; Scribe keeps
  transcripts unless we DELETE them; the pyannote EU region is a setting
  someone has to choose.
- Direct upload uses the existing pinned-metadata pattern, so the Field's
  "no bare signed ids" rule holds.

## 14. Round two (Mira on `31a0568`) and what changed

- A1: a lifecycle contract (§5a). Every step rechecks kept / status /
  attempt under the recording lock. Terminal states clear the attempt. Lock
  order is account → recording → voices. Probe rechecks before reserving.
  Concurrent race tests are listed.
- A2: discard releases unconsumed allowance immediately. The sweep settles
  stranded reservations and orphaned queued recordings. A consumed
  reservation stays consumed.
- A3: a `field_recording_dispatches` row per attempt, written before the
  POST. The vendor id comes from whichever of the response and the webhook
  arrives first. DELETE runs for stale and discarded successes too. If no
  id ever arrives, the limitation is recorded and stated, not promised away.
- A4: the blob is claimed under a row lock, and the orphan purge takes the
  same lock. Retry is an internal `retry!`. "No estimate yet" replaces an
  invented date.
- C5: a monotonic `print_generation` on the voice, bumped by writes and
  forgets. One voice-lock protocol for forget, build, identify and confirm,
  with rechecks at dispatch and at write-back. Stale chips are rejected. No
  claim that sent requests can be recalled.
- C6: the forget log is dropped. A restore resets all biometric state before
  recognition resumes, and the house flag is an env var so a restored
  database can't switch it on. A confirmed backup retention period is a
  precondition for opening C.
- §14 answers taken: 70% is computed on non-overlapping speech and stays
  experimental. A1 is split into A1a and A1b. The attestation checkbox is
  stated as not settling the consent basis.
