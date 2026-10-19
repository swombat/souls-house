# Field voiceprints made, applied and improved in the house

*2026-10-19 · Lume · asked for by Daniel in KJkkdJ ("Souls.house should be doing
the voice fingerprinting, applying the voice fingerprinting, and also improving
the fingerprints over time"); engine chosen by Daniel the same day: ECAPA, run
in the house. Draft for Mira's review. Nothing here is built.*

## 1. Where things stand (checked in prod, 2026-10-19)

- The house's own recognition (spec 2026-10-08 §9, pyannote) has never run:
  no `SOULSHOUSE_FIELD_VOICEPRINTS`, no pyannote key, no account with
  `recognise_voices`. 0 prints, 0 enrolments, 0 recognitions.
- The names that appear on their own come from the Mac:
  `lume/tools/grove-sync/identify.py` embeds unnamed speakers with speechbrain
  ECAPA (`spkrec-ecapa-voxceleb`, 192-d) and compares them with per-person
  centroids in `pa/capabilities/voice-fingerprint/data/cache.json` (19 people,
  most from one recording). A clear match (cosine ≥ 0.55 and ≥ 0.15 ahead of the
  runner-up) is written through the API as a plain naming.
- Nothing learns. Naming a speaker in the house links it to a voice and
  nothing more; the Mac cache only changes when someone reruns its build
  scripts by hand.
- **Provenance is lost.** All 926 named speakers read `named_by: User 1,
  naming_source: human`, whether Daniel clicked or the Mac script matched.
- Pilot evidence for ECAPA, May 2026: leave-one-out over 14 (file, speaker)
  instances, five people. 12/12 correct for people with two or more
  recordings; single-recording people can't be tested that way. One
  single-sample print (Ellen, a phone call) matched every phone-quality voice
  and was switched off. This is encouraging, not a demonstrated accuracy.

## 2. What we're building

1. **An ECAPA service in the house**, beside the memory-embeddings accessory.
2. **Samples from every human-confirmed naming.** Each confirmed speaker
   contributes an embedding of their clean speech in that recording.
3. **A voice's print is the mean of its eligible samples**, rebuilt whenever a
   sample is added or removed. That is the "improving over time".
4. **Matching in the house**, replacing the pyannote identify call: unnamed
   speakers are compared with prints and get a guess ("Tomás?") to confirm.
5. **A held-out check** that measures each print against recordings it wasn't
   built from, and keeps a print from guessing until it passes.
6. **A backfill** from the names already in the Field, with provenance
   handled as §5 says.
7. **The Mac script retires** once the house does at least as well on the
   same held-out set (§8).

Out of scope: diarization (Scribe's speakers stay as they are), supplied
transcripts without word timings, any new consent mechanism (Daniel: this is a
private database, no change needed), backup expiry (Daniel: separate, if it
becomes a problem).

## 3. The service: `services/voice-embeddings`

Same pattern as `services/mnemodyne-embeddings`:

- `python:3.11-slim`, `speechbrain` + CPU `torch` + `torchaudio`, versions
  pinned in `requirements.txt`. Model weights (`speechbrain/spkrec-ecapa-voxceleb`)
  downloaded at build time, checked against a `model-sha256.json`, run
  offline (`HF_HUB_OFFLINE=1`). Licence to confirm at build (model card says
  Apache-2.0; check before shipping).
- Kamal accessory `voice-embeddings`, no public port, `souls-house-voice-embeddings`
  on the private network, read-only filesystem, tmpfs `/tmp`, non-root user,
  pinned by digest (`HOUSE_VOICE_EMBEDDINGS_DIGEST`, written by a
  `bin/house release-voice-embeddings` like the existing one). Memory 1g, 2 CPUs
  to start; measure.
- Bearer token `VOICE_EMBEDDING_TOKEN` (≥ 24 chars) on web/jobs and the
  accessory.
- `GET /health` → `{ready, profile, dimensions: 192}`; `profile` names model,
  weights hash and library versions, so a sample records exactly what made it.
- `POST /embed`, body = one WAV, mono 16 kHz (what `FieldVoiceprints::Sample.cut`
  already produces), ≤ 120 s, ≤ 8 MB. Returns `{embedding: [192 floats],
  profile}`. One request at a time (semaphore), short socket timeout, no
  request content in logs. The service keeps nothing.

Audio never leaves the house. The service is an implementation detail behind
`VoiceEmbeddingClient` in Rails; nothing else talks to it.

## 4. Data

**`field_voice_samples`** (new), one per (voice, recording speaker):

| column | |
|---|---|
| `account_id`, `field_voice_id`, `field_recording_speaker_id` | unique on voice + speaker |
| `embedding` | encrypted (non-deterministic), never serialised, like `FieldVoiceprint#print` |
| `speech_ms` | clean speech used |
| `profile` | the service profile that made it |
| `label_origin` | `human` · `confirmed_recognition` · `machine` · `unknown` (§5) |
| `eligible` | true only for `human` and `confirmed_recognition` |
| `created_at` | |

**`field_voiceprints`** keeps its role and its generation protocol (spec §9 C5,
the voice lock, rechecks at write). `print` becomes the mean of the voice's
eligible samples with the current profile, L2-normalised, plus
`sample_count`, `recording_count`, `engine: "ecapa"` and `profile`. Samples
made with an older profile are re-embedded, never mixed.

Forgetting a voice destroys its print **and its samples**, and sets
`remember: false` on the voice so new namings stop adding samples until
someone turns it back on from the Voices page. Un-naming or renaming a speaker
destroys that speaker's sample and rebuilds the print. Discarding a recording
destroys its samples.

## 5. Provenance: what may train

Mira's rule, adopted: **a print learns only from labels a person made or
confirmed. A machine's guess never trains itself.** Provenance fails closed:
anything not positively known to be a person's decision is not eligible.

- `naming_source` gains `machine` and `unknown`.
- **Web clicks** (`FieldRecordingSpeakersController`, a signed-in person in
  the browser) are `human`. **A confirmed guess** is `confirmed_recognition`.
  Only these two are eligible.
- **Every API naming is `machine` by default.** The speakers API
  (`/api/v1/field/...`) records `machine` whether or not the client says
  anything, so an old Mac script that sends no provenance can never produce a
  training label. There is no API flag that makes a write `human`. A person's
  decision only enters through the page, or through the confirm list below.
- **Existing 926 rows start as `unknown`.** Absence from a log isn't proof of
  a human (Mira). Ways out:
  1. *Evidence*, which is thin (checked 2026-10-19). Request logs live only in
     each web container's json-file log (10 MB cap, no volume). Every deploy
     starts a new container and keeps only the previous one, so logs reach
     back hours. A row becomes `human` only if a surviving web-controller
     request named **that speaker to its current voice**, and no later naming
     of that speaker (from any route) superseded it. A route alone is not
     enough. Anything unresolved stays `unknown`.
  2. *Confirmation*, which is the real route. A review list on the Voices
     page, per voice: "Confirm these N names", playing a few seconds of each.
     One tap confirms a speaker (→ `human`, `named_by` the person who tapped),
     and one marks it wrong (un-names it).
- Tests: an old-client API write with no provenance field stays `machine`;
  a historical speaker named by the web and then re-named by the API is not
  `human`; a speaker named by the API and then confirmed on the page is
  `human`.

## 6. Samples

Reuse `FieldVoiceprints::Sample.segments_for`, with two changes for learning:

- keep the isolation rule (no other speaker within 1 s) and the "fewer voices
  than expected" refusal;
- per-sample minimum 4 s of clean speech (was 8 s for a single enrolment),
  maximum 60 s, longest turns first. A speaker under 4 s contributes nothing.

A sample is made by a job after an eligible naming commits (`after_commit`),
under the freshness contract in §9. No human listens before a sample is used.
That is a risk, not something averaging removes. A mixed or mislabelled sample
still pulls its print. Averaging only reduces its weight once a voice has
several recordings, and does nothing for a single-recording voice. §7's
checks are what catch it, and the review list's "maybe not this person" flag
is how a person sees it.

## 7. Measuring accuracy

### 7.1 What is measured

Queries are **(recording, speaker)** pairs whose label is eligible (§5). The
labels come from people, and the scores come from the production matcher (§8)
with its real threshold, margin and duplicate-speaker rule, never a simplified
"nearest print" score.

For each query recording R, every print used to score it is rebuilt **without
any sample from R**, for every voice and every diarized fragment of R. That
covers the target voice and every other voice. No audio from R is in any
reference.

Each query has one of four outcomes:
- **correct**: the matcher guesses the labelled voice;
- **wrong**: it guesses another voice. This is a false accept, **charged to the
  print that won**;
- **rejected**: no guess (below threshold, margin or duplicate rule);
- for **other-person** queries (speakers labelled as a named person who has no
  print), any guess is a false accept charged to the winning print. Speakers
  set aside as **anonymous** count as negatives only when known not to be an
  enrolled person (a person confirmed that on the review list). Otherwise an
  anonymous speaker may be someone with a print, and isn't scored.

### 7.2 Per-print activation

A print may produce guesses ("active") only when, over its held-out data:
- it has samples from ≥ 2 recordings, with ≥ 2 correct and ≥ 80% of its own
  queries correct; and
- it has **zero false accepts into it** from other people's queries, with at
  least 10 negative queries scored against it (other voices' and other-person
  queries).

A print that can't be measured this way (one recording, or too few
negatives) is **not validated**. It stays inactive by default. The Voices page
can turn a voice's unvalidated print on, and its chips then read "maybe
Tomás? (not yet checked)". Unvalidated prints are excluded from every accuracy
figure and are never auto-applied.

Validation results are tied to the sample set they were computed on, and are
recomputed whenever that set changes (§9). Stale validation means inactive
until recomputed.

### 7.3 Tuning and comparison use different data

Recordings are split once, by recording and stably (hash of recording id):
- a **tuning set**, used to choose the threshold and margin;
- a **comparison set**, used only for the house-vs-Mac comparison in §8 and
  the figures shown to Daniel.

Comparison-set audio is absent from the house's reference prints and from the
Mac cache's samples for that run. The Mac side is rebuilt from
`embeddings.json` minus comparison recordings, or that recording is dropped
from the comparison if it can't be. Both systems answer the identical query
list.

### 7.4 Reporting

`field:voiceprint_report` prints, per voice and in total: correct, wrong
(false accepts into it, and by it), rejected, the number of queries, and
whether the print is validated. If there are too few comparison queries to
say anything (fewer than 30 eligible queries across at least 5 voices), the
report says **"insufficient evidence"** and no comparison counts as passed.
The Voices page shows the same per-voice line.

## 8. Applying prints

`FieldVoiceprints::Identification` stops calling pyannote. After a recording
is transcribed (and on "Look for known voices again", #459):

- each unnamed, un-ignored speaker with ≥ 4 s of clean speech is embedded;
- cosine against every **active** print; a guess when the best is ≥ the tuned
  threshold and ahead of the second by the tuned margin (starting points: the
  Mac's 0.55 and 0.15, set from the tuning set, §7.3);
- two speakers in one recording matching the same voice: both stay unguessed
  unless both clear the split threshold (Mac: 0.75), as `identify.py` does;
- the guess is the existing recognition chip. Confirm → `confirmed_recognition`
  (trains), dismiss → nothing learned.

**Question for Daniel:** should a very confident match from a **validated**
print be applied as a name without a tap, as the Mac does today? If yes, it's
recorded as `machine` and never trains. Unvalidated prints never auto-apply.
Chips are the default either way.

Retiring the Mac script: on the comparison set, the house must have
**correct ≥ the Mac's and wrong ≤ the Mac's** on the identical queries, and
the report must not say "insufficient evidence". Then `identify.py` stops
running (its `--identify` waiter in `tilerec_intake.py` is removed) and
`cache.json` becomes history. Until then both run, and the Mac script's writes
are `machine` (§5).

## 9. Learning freshness: queued work can't undo a decision

The sample job runs after embedding, which can take seconds and can be
delivered twice. Anything a person does meanwhile wins.

Two counters on the voice, kept apart so samples don't cancel each other:
- **`learning_generation`** changes only when the whole voice's learning is
  revoked: Forget. Jobs are checked against it. Revoking one speaker's sample
  (un-name, rename, discard) is caught by that speaker's own checks below, so
  it doesn't touch sibling jobs either.
- **`print_generation`** changes whenever the centroid is rebuilt, including
  after every sample write. Chips and guesses are checked against it, as now.
  A job never checks it, so one sample landing doesn't invalidate the
  others queued for the same voice.

**Snapshot when the job is queued:** speaker id, the speaker's
`decision_generation`, its `field_voice_id`, its `naming_source`, the voice's
`learning_generation` and `remember` flag, the recording's id, and the service
profile.

**Recheck under the lock order (account → recording → voice) before
writing anything,** with fresh rows. Write nothing (and drop the embedding) if
any of these has changed or no longer holds:
- the recording is kept and ready;
- the speaker's `decision_generation` and `field_voice_id` are as snapshotted,
  and its `naming_source` is still eligible;
- the voice is kept, `remember: true`, and its `learning_generation` is as
  snapshotted. A Forget bumps it, so work queued before a Forget can't write
  after a "Remember again";
- the service profile still matches the current profile.

The sample is upserted by (voice, speaker) under that lock, so duplicate
delivery writes one row. Each write then rebuilds the centroid from **all**
current eligible samples (not by adding to the previous one), bumps
`print_generation` and marks validation stale. Because the rebuild reads every
sample under the voice lock, two jobs finishing in either order give the same
print.

**What each decision does, all under the same locks:**
- *Forget*: destroys the voice's samples and print, bumps `learning_generation`
  and `print_generation`, clears guesses that came from that print, sets
  `remember: false`.
- *Remember again*: sets `remember: true`. It does not revive old samples;
  learning restarts from eligible namings, re-queued fresh.
- *Un-name / rename a speaker*: bumps the speaker's `decision_generation` (so
  its in-flight job writes nothing), destroys its sample from the old voice,
  rebuilds and invalidates the old voice's print, and clears guesses made from
  it. Other speakers' jobs for that voice are unaffected. A rename then queues
  a sample for the new voice.
- *Discard a recording*: destroys every sample from it and rebuilds the
  affected prints. Jobs for its speakers fail the "recording is kept" check.
- *Profile change* (a new model build): samples on the old profile are
  re-embedded by a backfill job. Prints use only one profile at a time and
  are inactive until rebuilt and re-validated.

**Acceptance tests:** two samples for the same voice from different speakers
queued together, completing in both orders: both samples kept, the same print
either way; a backfill of N speakers for one voice keeps N samples; duplicate
job delivery; Forget while an embedding is in
flight; Forget → Remember again while an old job is queued (the old job
writes nothing); un-name and rename in flight; discard in flight; profile
change in flight; a confirmed guess whose print was rebuilt before the
confirm (existing stale-chip rules still refuse it).

## 10. Gates and the pyannote path

- House gate: `SOULSHOUSE_FIELD_VOICEPRINTS=on` and the voice-embeddings
  accessory healthy (replaces "pyannote configured"). Account gate unchanged.
- Enrolment ("Remember this voice") is no longer needed to start a voice: a
  kept voice with `remember: true` (default) learns from its namings. The
  explicit flow becomes "Forget" and "Remember again".
- The pyannote client, enrolment dispatch and identify collector are removed
  in the slice that switches matching over; nothing has ever been sent to
  pyannote, so there is nothing there to forget.

## 11. Slices

- **A. Provenance first.** `machine` and `unknown` naming sources, every API
  write recorded as `machine`, existing rows marked `unknown`, the narrow log
  reconstruction (§5.1). Small, and it has to land before any sample exists.
- **B. The service.** `services/voice-embeddings`, accessory, client, health
  check, release command. Deployed and idle.
- **C. Samples and prints.** Table, sample job, mean print, forget/un-name
  cleanup, the freshness contract and its tests (§9), the measurement and
  report task (§7). Backfill of eligible names.
- **D. Matching.** House identify replaces pyannote; chips; #459's button
  uses it; thresholds tuned on the tuning set only (§7.3).
- **E. Review list and Voices page.** Confirm-these-names, per-voice accuracy.
- **F. Retire the Mac script**, after the comparison in §8 passes on the
  comparison set.

Each slice is its own PR, reviewed by Mira.

## 12. Open questions

1. Auto-apply above a high threshold (§8)? Daniel.
2. ~~How far back do the host's request logs go?~~ Hours, not days (§5.1), so
   the confirm list (§5.2) carries the backfill.
3. Thresholds: start from the Mac's, then set on the tuning set (§7.3).
   Re-check after the first month.
4. CPU on the house host during backfill: measure with slice B (ECAPA on 60 s
   is expected to be around a second or two of CPU; unmeasured here).
