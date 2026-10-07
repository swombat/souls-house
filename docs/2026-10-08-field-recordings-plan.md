# Field recordings: plan

*Lume, 2026-10-08. For Mira's review and Daniel's decision. Mockups: the
"Recordings in the Field" Stone in conversation weVzle.*

## What Daniel asked for

Add recordings to the Field and transcribe them, with a default cap of about
20 hours a week per account. Voice prints should get set up the way they did
for Daniel's own recordings, without an enrolment chore. Prints stay inside the
account (Daniel, weVzle).

## The one design idea

**There is no voice-print setup step. Naming a speaker once is the
enrolment.** A first recording comes back as "Speaker 1, 2, 3". Each speaker
has a 5-second clip and a "Who's this?" chip. Once you name a speaker, the
Field keeps a print for that person in this account. On later recordings it
labels them itself, shows a dotted "Tomás?" when it isn't sure, and asks
nothing when it is. The only question asked up front is "which one is you?",
and it is asked once.

Everything else in this plan serves that idea or keeps it honest.

## What exists today (read from master `1c48b29`)

- `FieldFile` covers account-level files with title and note, discard
  semantics and a 100 MB cap. Tabs: All / Files / Notes
  (`app/frontend/pages/field/index.svelte`).
- `ElevenLabsStt` (`lib/eleven_labs_stt.rb`) uses Scribe v2, but synchronously,
  with a 60 s read timeout, `timestamps_granularity: none` and no diarization.
  That suits voice notes but not hour-long recordings.
- ffmpeg is in the image (`Dockerfile`, already used by
  `TelegramVideoPreview`).
- `MeteredActionEvent` has windowed request and spend policies. A per-account
  rolling allowance could reuse its shape.
- `DeviceStream` already models "streams about a person with explicit
  readers". That's a useful precedent for consent wording, but it's not
  needed here.

## Vendors

- **Transcription: ElevenLabs Scribe v2**, which we already pay for and which
  handles Spanish, Catalan and English well. Ask it for `diarize: true`,
  `num_speakers` when known, and word-level timestamps. Long files must go
  through Scribe's async path (webhook or polling), not the current 60 s call.
  *To verify before building: Scribe's current maximum file size and duration,
  and the async contract.*
- **Voice prints and recognition: pyannoteAI** (`docs.pyannote.ai`).
  `POST /v1/voiceprint` takes at most 30 s of single-speaker audio and returns
  a print. *We* store the print, because pyannote deletes job output after
  24 h and keeps no print database for us. `POST /v1/identify` takes a
  recording and the prints we pass in, with `matching.threshold` and
  `matching.exclusive`, and returns speaker segments with a match and a
  confidence for each. Billing is per second for identify and per print for
  voiceprints. Their docs say customer audio isn't used for training and
  inputs are deleted after processing. *To verify: DPA terms and processing
  region.*

One honest correction to what I said in chat: with pyannote, confirming a
name doesn't average anything into the print. A person has one print made from
up to 30 s of clean speech. "Getting stronger" means replacing the sample with
a longer, cleaner one when a later confirmed recording offers it. The UI's
strength meter should measure that (seconds of clean speech in the sample),
not imply learning that doesn't happen.

## Pipeline

1. **Upload.** Use a direct upload (ActiveStorage direct upload, not through
   the Rails process), because four hours of m4a passes 100 MB. Raise the cap
   for recordings only, to about 1 GB. Run `ffprobe` for duration, then the
   **allowance check** (below). Create a `FieldRecording` in `queued`.
2. **Transcribe** (`FieldRecordings::TranscribeJob`). Send it to Scribe with
   diarization and the expected speaker count. Store the normalised transcript
   (words with start, end and Scribe speaker id) as JSON on the recording, plus
   a rendered plain-text version for residents and search.
3. **Recognise** (`FieldRecordings::IdentifyJob`). This runs only if the
   account has voices and recognition is on. Send `/identify` with every
   print in the account (`exclusive: true`). Then assign speakers.
   - **Decision for Mira: whose diarization wins.** Scribe and pyannote each
     diarize, and they will sometimes disagree. Option A: Scribe's speakers are
     the truth, and each Scribe speaker takes the pyannote match it overlaps
     most in time, as long as that overlap is at least 60% of its talk time;
     otherwise it stays unknown. Option B: pyannote's turns are the truth, and
     Scribe words are dropped into them by word midpoint. **I lean B.**
     pyannote's diarization is the better of the two, and a word-to-turn
     assignment fails in small pieces instead of mislabelling a whole speaker.
     The cost is calling pyannote's diarization even when the account has no
     prints yet. (`/identify` cannot also transcribe, per their docs, so
     there are always two calls.)
4. **Suggest** (`FieldRecordings::SuggestSpeakersJob`). A utility-model call
   reads the transcript, the title, the note and the account's known names. It
   returns at most one suggestion per unknown speaker, *with a quoted line as
   evidence* ("talks about 'my venue contract' at 04:12"), or nothing. A
   suggestion without a quote is dropped.
   - **Decision for Daniel: who is speaking.** The mockup credits the
     account's resident ("Wren thinks…"). If it's a utility call, the UI must
     not say a resident thought it. Either label it "Suggested from what's
     said", or really wake the resident (that costs inference, but it's
     truthful and it's the souls.house version). I'd ship the plain label
     first and offer "ask Wren" as a button that does wake the resident.
5. **Name** (user taps). This creates or links a `FieldVoice`, then
   `FieldRecordings::BuildVoiceprintJob` cuts a clean sample with ffmpeg. The
   sample is that speaker's longest turns with no overlap, joined, at least
   8 s and at most 30 s. Turns within ±0.5 s of anyone else are skipped. Then
   it calls `/voiceprint` and stores the result. **No print is built from a
   speaker shorter than 8 s of clean speech**, and no print is built when the
   expected-count field was used and the diarizer found fewer speakers than
   expected. That guard is the merged-voice lesson: a wrong speaker count
   merges two people into one speaker, and a print built from that speaker
   corrupts every later match. *(Unverified: whether Daniel's own prints were
   made this way or from deliberate clips. I couldn't reach the TileRec skill
   from the house body. The guard stands either way.)*

Confidence bands on the identify output: ≥ 75 shows the name solid, 50–75
shows it dotted ("Tomás?" with confirm/fix), below 50 leaves the speaker
unknown. These are starting numbers to tune against Daniel's archive, not
claims.

## "Which one is you?"

After the uploader's second completed recording, if one unnamed speaker has
the most talk time in both *and* `/identify` says it's the same voice, ask
once: "Is that you, Sam?" A yes builds the uploader's voice linked to their
`User`. A no is remembered and the question never comes back. "You" also
leads every Who's-this chip, so nobody has to wait for the prompt.

## Data

- `field_recordings`: account, uploaded_by (polymorphic, as FieldFile), title,
  note, `expected_speakers` (nullable), `duration_seconds`, `status`
  (queued / transcribing / recognising / ready / failed), `failure_reason`,
  `transcript` (json), `transcript_text`, discard. Audio is
  `has_one_attached :audio`. Recordings show up in the All tab and in a new
  Recordings tab.
- `field_recording_speakers`: recording, `diarization_label`,
  `field_voice_id` (nullable), `state` (unknown / suggested / guessed /
  confirmed), `confidence`, `talk_seconds`, `sample_start` / `sample_end`
  for the 5 s clip, plus suggestion text and its quote.
- `field_voices`: account, `name`, `user_id` (nullable, set when the voice is
  an account member), `named_by` (polymorphic), `voiceprint` (**Active Record
  encrypted**), `sample_seconds`, `sample_recording_id`, timestamps. **Never
  serialised** to the API, to residents or to Inertia props. Only the name and
  the strength leave the model.
- Account: `recording_seconds_weekly_limit` (default 72_000) and
  `recognise_voices` (default on, see consent).

## Forgetting is real deletion (an exception to the discard rule)

The project rule keeps rows and bytes on delete. That rule must not apply to
prints. "Forget this voice" **destroys** the `field_voices` row and its print,
and nulls `field_voice_id` on speakers. The names already shown in
transcripts stay as plain text, because those were the user's words. A print
is biometric data used to identify someone (GDPR Art. 9). Keeping it after
someone asks for it to be forgotten is exactly what we must not do. A test
should pin this down: after forget, no print row exists, and the next
identify call doesn't send it.

## Consent (settled vs open)

Settled by Daniel: prints exist only within their account. They are never
shared across accounts, never exposed to residents or the API, and never used
for anything except labelling this account's recordings.

Built in v1:
- the "Voices this Field knows" page, where every print can be forgotten by
  any account member;
- a one-line note the first time you name someone who isn't an account member:
  "Saving Priya's voice lets this Field recognise her. Only do this if she'd
  be fine with it.";
- an account toggle, "Recognise voices automatically". When it's off,
  `/identify` is never called and naming stays per-recording only.

**Open, for someone who knows the law:** whether recognising non-members
needs more than the uploader's word (Art. 9 explicit consent of the person
named). It's not mine to settle. The design keeps the cheap exit: with the
toggle off by default, v1 still works fully as transcription with manual
naming.

## The weekly allowance

- 20 h per account over a **rolling 7 days**, not a Monday reset, so heavy use
  frees up gradually rather than in a cliff.
- The audio duration is reserved at upload (`ffprobe`) and released if the job
  fails. A file longer than the remaining allowance is refused before upload
  with the exact time room frees up ("from Tue 14 Oct, 09:10").
- A gauge in the Recordings tab: "3 h 20 m of 20 h this week". No upsell
  language.
- The limit is a column, so Daniel can raise it for an account without a
  deploy.
- *Cost note:* I haven't priced Scribe plus pyannote per hour from their
  current price pages. That should be done before the default is final rather
  than guessed here.

## Residents

Residents read a recording's `transcript_text`, with names, through the same
Field API as files. They see speakers' names and never prints. A resident may
suggest or correct a label through the API. It can't confirm one: a print is
built only from a human tap. That keeps the biometric act a human act.

## Phases

1. **Recordings and transcripts.** Upload, allowance, async Scribe with
   diarization, transcript view, a per-recording Who's-this naming that
   creates a `FieldVoice` *without* a print, the Recordings tab and the gauge.
   Useful on its own.
2. **Recognition.** pyannote prints and identify, confidence bands, the
   dotted-guess UI, "which one is you", the Voices page, the toggle and real
   deletion.
3. **Suggestions.** The utility suggester with quoted evidence, and an "ask
   Wren" that wakes the resident.

## Tests that matter more than the rest

- A forgotten voice leaves no print and is never sent again.
- No print is built from a speaker under 8 s, or when fewer speakers were
  found than expected.
- Prints never appear in any JSON a member, a resident or the API can receive
  (a serializer test over every Field endpoint).
- The allowance holds at the boundary and is refunded on failure.
- The word-to-turn merge (option B) is checked on a fixture with overlap.

## Questions for Mira

1. Option A or B for whose diarization wins?
2. Is Active Record encryption enough for prints, or do they want their own
   key?
3. Should naming in phase 1 (no prints) reuse `FieldVoice` or stay a plain
   label on the speaker until phase 2? I lean reuse, so phase 2 has names to
   attach prints to.
4. Anything in the allowance reservation that races (two uploads at once)?
