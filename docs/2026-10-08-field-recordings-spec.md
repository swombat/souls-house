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
| `vendor_request_id`, `vendor_transcription_id` | ElevenLabs ids, nullable |
| `attempt_token` | random per dispatch; the webhook must echo it (§5) |
| `transcript_words` | jsonb: `[{s, e, t, spk}]`, ms ints, Scribe words and audio events, exactly as Scribe returned them apart from compaction |
| `transcript_text` | rendered text with names (rebuilt when names change) |
| `language_code` | from Scribe |
| `ready_at` | |
| `discarded_at` | Discard. The recording is discardable like a file |

`has_one_attached :audio`. Index on `[account_id, created_at]`, plus a unique
index on `vendor_request_id`.

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
| `recognised_voice_id`, `recognition_confidence`, `recognition_voiceprint_version` | slice C. A recognition is a *guess* until a human confirms it |

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
| `version` | int. Bumped on every replace |
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
   `title`, `note` and `expected_speakers`. The server accepts the blob only
   if its metadata names **this user and this account**, `expires_at` (6 h)
   hasn't passed, and the blob isn't attached to anything. Otherwise it's a
   422 that says nothing about the blob.
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
past `expires_at`, and purges the audio of `rejected` recordings after 24 h.
A rejected recording isn't something anyone brought into the Field, so the
discard rule doesn't apply to it.

Residents do **not** upload recordings in slice A. The resident Field API
stays files-only for writes.

## 5. Transcription (slice A)

`FieldRecordings::TranscribeJob(recording_id)`:

1. Under `recording.with_lock`: if the status isn't `queued`, return (this
   is what makes the job idempotent). Set `transcribing`, generate a fresh
   `attempt_token`, save.
2. POST to Scribe: `model_id=scribe_v2`, `diarize=true`,
   `timestamps_granularity=word`, `tag_audio_events=true`,
   `num_speakers=expected_speakers` when given, `webhook=true`,
   `webhook_id`, and
   `webhook_metadata={"recording": <obfuscated id>, "attempt": attempt_token}`.
   The file goes as `cloud_storage_url`: a signed blob URL valid for 6 h.
   With local storage in development, the file is posted as multipart.
3. Store `request_id` and, if present, `transcription_id`.

`POST /webhooks/elevenlabs/stt` (no session, CSRF skipped):

1. Verify the HMAC signature against `stt_webhook_secret`, with a timestamp
   tolerance of 5 min. If it fails: 401, nothing touched.
2. Find the recording by obfuscated id. If it isn't `transcribing`, or the
   `attempt` doesn't match its `attempt_token`, return 200 and ignore it.
   That covers duplicates, a stale attempt after a retry, and a recording
   discarded meanwhile.
3. In one transaction under the recording lock: store the words, create the
   speaker rows (talk time, clip choice: the longest turn of that speaker
   with no other speaker within 1 s, trimmed to 5 s), render
   `transcript_text`, set `ready`, and **consume the reservation** (§6).
4. After commit: `DeleteVendorTranscriptJob` calls Scribe's DELETE, retrying
   up to 3 times, and logs (without the content) if it can't. Then broadcast
   to the account, and in slice B enqueue suggestions.

**When no webhook arrives.** `FieldRecordings::StuckSweepJob` (every 10 min)
looks at `transcribing` recordings older than
`max(20 min, 0.5 × duration)`. If a `transcription_id` is known, it GETs the
transcript and processes it exactly as the webhook would, through the same
method with the same guards. Otherwise, or if the GET fails, the dispatch
counts as one failed attempt. Each recording gets at most **3 dispatches**.
After that it's `failed` and the reservation is released. Every dispatch
costs vendor money, so the cap bounds spend separately from the allowance.

**Errors at dispatch.** A 4xx other than 429 → `failed` straight away, with
Scribe's message, and the reservation released. A 429, a 5xx or a transport
error → back to `queued` with a backoff (1, 5, 15 min), counted against the
3 dispatches.

**Discarding a recording mid-flight.** The webhook guard ignores the result
and the reservation stays `pending` until the sweep finds a discarded
`transcribing` recording. If the transcription had already been consumed, it
stays consumed: the vendor did the work.

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
- **consume**: on a successful transcript. Exactly once. Later failures
  (suggestions, recognition) never refund it.
- **release**: on `failed` or `rejected`, or a discard before consumption.
  A released recording can't be re-queued. "Try again" creates a new
  recording from the same blob, with a new reservation, through the same
  check.

**What people see.**
- The gauge in the Recordings tab: "3 h 20 m of 20 h used in the last 7
  days". Pending reservations are included and marked "(1 h 10 m still
  transcribing)".
- Over the limit: "This recording is 2 h 05 m. You have 1 h 40 m left this
  week. Room frees up gradually; enough for this one by about Tue 14 Oct,
  09:10." That time is computed from consumed rows only and labelled
  "about", because pending work can change it.
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

**Cost note.** I haven't priced Scribe-with-diarization per hour, or pyannote
identify, from their current pages. Both need checking before the 20 h
default is final. Suggestions are one small call per recording.

## 9. Recognition (slice C, gated)

### The gate

Recognition does anything at all only when **both** the house flag
`field_voiceprints` (default off) **and** `account.recognise_voices`
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
that's settled, the house flag stays off in production. Slice A and B don't
depend on it.

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

### Building the print

`FieldVoices::BuildPrintJob(speaker_id, consent_token)`:

1. Recheck the gate, that the speaker is still named to that voice, that the
   voice is kept, and that the consent token matches a still-pending consent
   (a token row created by the tick, deleted on forget). Any failure: stop,
   and delete the token.
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
4. **Dispatch.** Upload the sample to pyannote `/voiceprint` via a 1 h signed
   URL. Poll the job (webhook optional, later).
5. **Write back**, under `voice.with_lock`: recheck everything in step 1
   *again* (a forget may have happened in between). If the consent token is
   gone, discard the result. Otherwise upsert the print, bump `version`,
   delete the temporary sample blob and the consent token.

**Replacing a print** happens only by the same explicit act on a later
recording ("Remember Priya's voice from this recording instead"), offered
when this speaker has more clean speech than the stored `sample_ms`. It's the
same job with a new consent row.

### Identifying

`FieldRecordings::IdentifyJob(recording_id)`, after `ready`, when the gate is
open and the account has at least one print:

1. Snapshot `{voice_id → version}` for every print in the account. Dispatch
   `/identify` with the audio URL, those prints (labelled by an opaque
   per-job key, never the name), `matching.exclusive: true`,
   `matching.threshold` (start at 50, a tunable constant),
   `numSpeakers`/`maxSpeakers` from `expected_speakers`, and model
   `precision-2`.
2. Poll. On completion, under the recording lock: for each print in the
   result, check the voice still has a print **with the same version as the
   snapshot**. If it doesn't, throw that match away. A forgotten or replaced
   voice can't be used by a late result.
3. **Diarization when both run (Mira's B, provisionally).** Scribe's words
   and speakers stay as they are. For each Scribe speaker, take the identify
   segments that overlap its words. If at least 70% of that speaker's word
   time lies in segments matched to one voice, and none of it lies in a
   segment matched to another voice, record that as a *recognition*
   (`recognised_voice_id`, confidence = time-weighted mean). Otherwise the
   speaker gets no recognition. Words in overlap or crosstalk aren't
   reassigned. If both diarizers' turns were adopted, we'd be choosing a
   truth; this way we only ever add a guess on top of the user's view.
4. Speakers already named by a human aren't touched. A recognition never
   sets `field_voice_id`.
5. Don't refund: identify failing leaves the transcription consumed.

Rerunning identify (a button on the recording, or after the Voices page
changes) replaces recognitions only. Human names and confirmations stay.

### Forgetting

**"Forget Priya's voice"** (Voices page, any account member):

1. In one transaction: **destroy** the `field_voiceprints` row, and delete
   any pending consent tokens and temporary samples for that voice. Clear
   `recognised_voice_id` / `recognition_*` on every speaker that points at
   it.
2. The name and the human labels stay. They're the account's own words about
   who spoke, and forgetting the *voice* doesn't rewrite the transcripts.
   The Voices page says so: "Priya's name stays on transcripts where someone
   named her. To remove those, rename or un-name them."
3. Because of the guards in BuildPrintJob step 5 and IdentifyJob step 2, a
   job queued or in flight can't recreate the print or use it.
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
  until they age out. `DatabaseBackupJob` uploads `pg_dump`s to S3 and
  expires nothing itself. Any retention would be an S3 lifecycle rule I can't
  see from here (owed: Daniel confirms). If there's no rule, backups keep a
  forgotten print indefinitely, and that is the case for the next sentence.
  A restore must re-apply forgets: the forget
  writes a `field_voice_forgets` row (voice id, time, no print), and a
  restored database's `FieldVoices::ReapplyForgetsJob` destroys any print
  older than a recorded forget. *(Mira: is this worth building in C, or is
  "until backups age out" the honest whole answer?)*

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
- The stuck sweep caps at 3 dispatches, then fails and releases.
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
- Cross-account: a voice, print or speaker from account A can't be read,
  named to, forgotten or sent in an identify request from account B.
- Serialiser sweep: no print in any JSON (§9).
- Overlap fixture: Scribe and identify disagree on a stretch → no
  recognition for that speaker, and no word reassigned.

## 12. Build order and review

1. **PR A1**: models, migrations, allowance ledger, upload endpoints, probe,
   Scribe client and webhook, sweeps, and the tests above. No UI beyond the
   tab listing.
2. **PR A2**: the recording page, the speaker strip, naming, the "You"
   prompt, the gauge, the resident API.
3. **PR B**: suggestions.
4. **PR C**: recognition behind the gate.

Each PR goes to Mira for review, and merges after her approval and green CI
on the exact head (standing rule). Deploying stays Daniel's call. Daniel's
setup steps in §2 are listed in each PR that needs them.

## 13. What changed from the reviewed plan (`a6e42a3`)

- Recognition is **off by default**, behind a house flag as well, and the
  flag stays off until the consent basis is settled. (Mira: consent.)
- Naming and remembering a voice are separate. Remembering is an unticked,
  explicit, per-person box with a preview of the sample and a "Not her" exit.
  No print is ever built as a side effect. (Mira: consent, phase 1.)
- Forgetting destroys the print row. Version and consent-token guards stop
  queued or late jobs recreating or using a print. Vendor and backup limits
  are stated, and there's a forget log to re-apply after a restore.
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

## 14. Questions for Mira's second look

1. Is the forget log and re-apply after restore (§9) worth building, or is
   "until backups age out", stated plainly, the honest whole answer?
2. The 70% / no-conflicting-match rule for recognition (§9, Identifying,
   step 3). Too strict, too loose, or the wrong shape?
3. Anything in the webhook guard (attempt token plus status) that a retry
   racing a late webhook can still get wrong?
4. Size: four PRs. Does A1 look like one reviewable PR to you, or should the
   allowance ledger be its own?
