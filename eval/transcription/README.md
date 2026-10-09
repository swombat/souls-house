# Transcription eval

How well does speech-to-text handle souls.house voice messages: mostly
Daniel and Paulina dictating into the composer, with names, product words and
code mixed in. This measures the model we use (ElevenLabs `scribe_v2`, see
`lib/eleven_labs_stt.rb`) against alternatives, on our own audio.

## What the data is, and isn't

The composer sends audio to Scribe, the speaker edits the returned text, and
the app stores only **the sent text and the audio**. The raw transcript was
never saved. So:

- Re-running `scribe_v2` on the stored audio stands in for the pre-edit text.
  The **edit rate** (WER between that rerun and the sent text) is how much the
  speaker had to fix.
- **Discarded messages are kept** (soft delete) and exported with a flag. A
  voice message deleted after posting is usually a transcript the speaker gave
  up on, so its sent text is the bad output, not a correction.
- **Sent text is not ground truth.** People leave errors in and sometimes
  rewrite instead of correcting. Disagreements get adjudicated (below), and the
  gold set should be checked by ear before anyone trusts a ranking from it.

## Steps

1. **Export** (someone with production access, once):

   ```sh
   bin/rails transcription_eval:export SPEAKERS=daniel@…,paulina@… OUT=tmp/transcription-eval
   tar czf transcription-eval.tgz -C tmp transcription-eval
   ```

   Only the named speakers' messages are exported, with the three messages
   before each one for context. The tarball is private conversation content:
   move it to where the eval runs and delete it afterwards. Never commit it.

2. **Transcribe** (cached per provider and sample; stop and resume freely):

   ```sh
   cd eval/transcription
   ELEVENLABS_API_KEY=… python3 transcribe.py CORPUS --providers scribe_v2
   GEMINI_API_KEY=… OPENAI_API_KEY=… python3 transcribe.py CORPUS --providers gemini-2.5-flash,gpt-4o-transcribe --limit 50
   ```

   Model names live in `providers.py`. Check them against each provider's
   current list before a run; add a line to try a new one. Start with
   `--limit` to price a run before running it all.

3. **Adjudicate** disagreements: `python3 judge_packets.py CORPUS` writes one
   packet per sample where the transcripts disagree. A text model (Sonnet or
   Haiku is enough) reads the context, the sent text and every transcript and
   writes `CORPUS/references/<id>.txt`. It can't hear the audio, so low-confidence
   answers go to a human.

4. **Report**: `python3 report.py CORPUS` writes `scores.csv`, `report.md`, and
   `gold.jsonl`: by default the 30 longest untouched samples (good) and the 70
   most edited or deleted ones (bad).

Tests: `python3 -m unittest test_textnorm test_pipeline` here, and
`bin/rails test test/lib/transcription_eval/exporter_test.rb` for the export.

## Scoring

WER on normalised words: case, punctuation and fillers (um, uh) ignored, common
contractions folded. A dropped "not" counts the same as any other word. That's
a known blind spot; the adjudication note is where meaning-changing errors get
called out.
