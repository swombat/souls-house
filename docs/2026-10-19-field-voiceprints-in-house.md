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
confirmed. A machine's guess never trains itself.**

- `naming_source` gains `machine` (written by a script through the API). The
  speakers API accepts `applied_by: "machine"` and records it; the Mac
  `grove_sync.py` and `identify.py` send it from the day this ships, before
  anything else here goes live.
- Web clicks (`FieldRecordingSpeakersController`) are `human`; a confirmed
  guess is `confirmed_recognition`. Both are eligible.
- **Existing 926 rows start as `unknown`, not eligible.** Absence from a log
  isn't proof of a human (Mira). Two ways out:
  1. *Evidence* (checked 2026-10-19, and it's thin): request logs live only
     in each web container's json-file log (10 MB cap, no volume), and every
     deploy starts a new container; only the previous one is kept, exited. So
     logs reach back to the deploy before last, usually hours. They can't
     vouch for history. Only a naming with a surviving log line becomes
     `human` (web controller) or `machine` (`/api/v1/`); everything else
     stays `unknown`.
  2. *Confirmation*: a review list on the Voices page, per voice, "Confirm
     these N names", playing a few seconds of each; one tap confirms a speaker
     (→ `human`), one marks it wrong (un-names it). Daniel's namings from this
     morning would be confirmed in minutes this way if the logs can't vouch
     for them.

## 6. Samples

Reuse `FieldVoiceprints::Sample.segments_for`, with two changes for learning:

- keep the isolation rule (no other speaker within 1 s) and the "fewer voices
  than expected" refusal;
- per-sample minimum 4 s of clean speech (was 8 s for a single enrolment),
  maximum 60 s, longest turns first. A speaker under 4 s contributes nothing.

A sample is made by a job after an eligible naming commits (`after_commit`,
deduplicated per speaker), under the same lock order as everything else. No
human listens first, because the print is no longer one sample: one bad
sample is diluted and caught by §7.

## 7. The held-out check

For a voice with samples from ≥ 2 recordings, leave-one-recording-out:
build the print without that recording's sample, then score the held-out
sample against every voice's print the same way. Record hit / wrong / miss.

- A voice's print is **active** (may produce guesses) when its held-out hits
  are ≥ 80% and wrong is 0, over ≥ 2 recordings.
- A single-recording voice is **active only if** its sample doesn't clear the
  matching threshold against any other voice's eligible samples (the Ellen
  case). Otherwise it waits for a second confirmed recording.
- Results are shown per voice on the Voices page ("recognised 5 of 6 held-out
  recordings") and in a `field:voiceprint_report` task that prints the whole
  table, so Daniel can see accuracy, not take it on trust.
- A sample whose own held-out score is far below its voice's others is
  flagged on the review list as "maybe not this person"; it isn't removed
  automatically.

## 8. Applying prints

`FieldVoiceprints::Identification` stops calling pyannote. After a recording
is transcribed (and on "Look for known voices again", #459):

- each unnamed, un-ignored speaker with ≥ 4 s of clean speech is embedded;
- cosine against every active print; a guess when the best is ≥ 0.55 and
  ≥ 0.15 ahead of the second (the Mac's thresholds, re-tuned from §7's data
  before launch);
- two speakers in one recording matching the same voice: both stay unguessed
  unless both are ≥ 0.75 (a diarizer split), as `identify.py` does today;
- the guess is the existing recognition chip. Confirm → `confirmed_recognition`
  (trains), dismiss → nothing learned.

**Question for Daniel:** should a very confident match (say ≥ 0.80 with a wide
margin, from a voice with a passing held-out check) be applied as a name
without a tap, as the Mac does today? If yes it's recorded as `machine` and
never trains; the chip is the default either way.

Retiring the Mac: when the house's held-out table is at least as good as the
Mac cache's on the same recordings, `identify.py` stops running (its
`--identify` waiter in `tilerec_intake.py` is removed) and `cache.json`
becomes history.

## 9. Gates and the pyannote path

- House gate: `SOULSHOUSE_FIELD_VOICEPRINTS=on` and the voice-embeddings
  accessory healthy (replaces "pyannote configured"). Account gate unchanged.
- Enrolment ("Remember this voice") is no longer needed to start a voice: a
  kept voice with `remember: true` (default) learns from its namings. The
  explicit flow becomes "Forget" and "Remember again".
- The pyannote client, enrolment dispatch and identify collector are removed
  in the slice that switches matching over; nothing has ever been sent to
  pyannote, so there is nothing there to forget.

## 10. Slices

- **A. Provenance first.** `machine` naming source, `applied_by` on the API,
  the Mac scripts sending it, existing rows marked `unknown`, the log
  reconstruction attempt. Small, and it has to land before any sample exists.
- **B. The service.** `services/voice-embeddings`, accessory, client, health
  check, release command. Deployed and idle.
- **C. Samples and prints.** Table, sample job, mean print, forget/un-name
  cleanup, held-out check and report task. Backfill of eligible names.
- **D. Matching.** House identify replaces pyannote; chips; #459's button
  uses it; thresholds tuned from C's report.
- **E. Review list and Voices page.** Confirm-these-names, per-voice accuracy.
- **F. Retire the Mac script**, after the comparison in §8.

Each slice is its own PR, reviewed by Mira.

## 11. Open questions

1. Auto-apply above a high threshold (§8)? Daniel.
2. ~~How far back do the host's request logs go?~~ Hours, not days (§5.1), so
   the confirm list (§5.2) carries the backfill.
3. Thresholds: start from the Mac's, then set from slice C's table. Re-check
   after the first month.
4. CPU on the house host during backfill: measure with slice B (ECAPA on 60 s
   is expected to be around a second or two of CPU; unmeasured here).
