# Field: recordings that arrive with their transcript

2026-10-09. Asked by Daniel (KekBnY): "add the ability to upload an audio file
_with the transcript already specified_ - because we don't want to retranscribe
all that stuff", so that "basically _all_ my recordings" can come into the Field.
Mira's conditions (same thread): keep provenance (original path, recording date,
existing transcript text), don't merge or drop raw and edited copies because
their filenames match, and make imports safe to rerun. Built in AjaBDJ.

## What it does

`POST /api/v1/field/recordings` takes, besides `upload_id`, either
`transcript_text` (plain text, parsed) or `transcript_turns`
(`[{speaker, start_ms, text}]`, speaker and start_ms optional). The recording is
created `ready` with `transcript_source: "supplied"`. Nothing is reserved and
nothing is sent to the transcriber. The probe still runs, and only records the
duration.

Parsing (`FieldRecording::SuppliedTranscript`) covers the shapes found in the
~700 archive transcripts in swombat/pa: `**Speaker A**: …`, `[00:04] speaker_0: …`,
`00:00 Daniel: …`, Meet notes (a time alone on a line, turns split by vertical
tabs, bold around a time and a name) and prose. A label counts only if some
label repeats. A leading paragraph is metadata, not speech, only if it has no
time, none of its labels recurs, and it is shaped like a block (two or more
lines, a markdown heading or rule, or keys like `Source:` / `Date:`); it is
kept, verbatim, as one unattributed turn. A speaker heard once, first, stays a
speaker. Nothing is dropped: an unlabelled line continues the turn before or
starts an unattributed one. Markdown list and heading lines are never speakers.

Checked against the archive (699 files) for fidelity, not only acceptance:
every alphabetic word and every line-start time in the source survives into the
turns; 646 parse with speakers, 53 as prose, 224 with times, none refused.
Known residue: some files keep a one-off pseudo-speaker such as "Topics",
"Source" or
"Speaker attribution" from a note or a mixed header; the text is intact. The
parser prefers that to swallowing a real opening voice.

## Guards that lived in dispatch

| Guard | For a supplied transcript |
| --- | --- |
| Size | Unchanged: upload declaration and create validation, 2 GB. |
| Weekly allowance | Not reserved. It meters what is sent to the transcriber; nothing is. |
| Dispatch exposure cap | Not touched, for the same reason. |
| Language | The caller's `language_code`, format-checked; not detected. |
| Speaker count | At most 100 distinct labels (Scribe's 32 bounds the diarizer, and there is none here; the archive has a 33-voice file). `expected_speakers` is dropped. |
| Transcript size | 1,000,000 characters. |
| Retry | Never offered; the recording is never failed or rejected. |
| Unreadable audio | The transcript stands; the duration stays unknown. |

## What has no word timings, and how the page degrades

`transcript_words` stays empty: no word timings are invented. The page shows
turns as plain text, with a clickable time only where one was given. Speakers
have no talk time (the API says `talk_ms: null`) and no "Hear" clip. Naming a
speaker works and re-renders the text. Voice recognition and name suggestions
are never queued, and a voice sample is refused with the reason. A speaker's
default name is the label the transcript gives, unless that label is generic
("Speaker A", "speaker_0"), which reads as "Speaker N".

## Provenance and reruns

`source_path`, `recorded_at` (ISO 8601 date or time) and `import_key` work on
any upload. `import_key` is chosen by the importer and never derived from a
filename. It is unique per account across every row, deleted ones included.
The same key again returns the recording it made (200, `existing: true`), and
its new upload is left for the orphan sweep. If that recording was deleted, the
call gets 409, so a rerun can't bring it back. `GET /api/v1/field/recordings?import_key=…`
checks before uploading.

## Not in this change

- A transcript with no audio. Every path here assumes bytes.
- The importer itself. The archive's audio is on Daniel's Mac, and the Mac-side
  script that pairs audio with transcripts and calls this endpoint is the next piece.
- The web upload form, which is unchanged.
