# 0006 — Switch voice embeddings to WeSpeaker for efficiency

## Status

2026-10-22: Daniel authorised replacing ECAPA with WeSpeaker in
[Audio fingerprinting technology](https://souls.house/accounts/gNDMev/chats/Wergmj),
message `jVzAgj`. **Accepted direction, not implemented or deployed by this
decision.** Daniel requested a direct-to-master documentation commit; the
implementation proceeds in the [WeSpeaker work thread][work] with Lume's review
before merge/deployment, under [ADR 0002](0002-reviewed-development.md).

This supersedes the ECAPA engine choice in the
[19 October design](../2026-10-19-field-voiceprints-in-house.md), not its
human-confirmation, privacy, freshness or validation requirements.

## Context

The offline study used **252 manually confirmed clips from 44 people**
(96.64 minutes). Dates were held out globally from enrollment. Candidates had
first been screened with ECAPA: human-confirmed identity truth does not remove
that selection bias. The resident-visible upload corpus excludes older
recording-backed references, including Daniel's voice.

Results from message `jxyARe` ([report][report], [private evidence bundle][bundle]):

- With two reference clips, production-style windowed ECAPA scored
  **211/216 (97.7%)**, versus whole-clip ECAPA and WeSpeaker at
  **212/216 (98.1%)** each. The diagnostic reproduced ECAPA's embedding recipe,
  not the complete production runtime or naming policy.
- On the matched 110-query cohort eligible for five references, all three
  recipes improved **109/110 → 110/110** from two to five clips. More clips also
  meant more reference duration, not a controlled test of session count.
  Ten-reference testing was unsupported without consuming holdouts.
- Likely remote-call → ALM and ALM → likely remote-call slices scored
  **24/24** and **25/25** respectively. Source/date-derived environment labels,
  different galleries and only three ALM dates prevent a general room-echo claim.
- These are known-person **nearest-match** results, not automatic-naming
  precision. The separate development-tuned rejection test had only **six
  unknown queries**. Zero observed false accepts cannot establish a low error
  rate or validate the live thresholds. Clean clips do not test diarization,
  overlapping speech or the complete activation/margin/duplicate-speaker policy.

**No recognition-quality superiority was established.** The initial private
`DECISION.md` recommended retaining ECAPA for continuity, while identifying
WeSpeaker as an efficiency challenger. Daniel chose the switch after the
additional recording-cost measurement, not because the quality evidence changed.

Efficiency evidence:

- Whole-corpus inference: **423.1 s ECAPA vs 122.0 s WeSpeaker**, four CPU
  threads, excluding load, decode and transport. These are elapsed inference
  times, not summed CPU-seconds.
- Message `jwbAxJ` ([profiling report][profile]): on a 71.4-minute recording,
  clean-speech rules selected 7 of 24 labels, totaling 204.28 seconds of audio.
  Two warm offline passes per engine on the Dell, with two inference threads
  and identical cuts, averaged **33.3 s vs 15.0 s elapsed**, including extraction
  and matching; actual CPU use was **62.0 vs 24.9 CPU-seconds** (about 60% less).
  This compares production-style ECAPA windowing with whole-clip WeSpeaker.
  Models were already loaded and probes treated as uncached; storage downloads,
  Rails/HTTP/database work and transcription were excluded. This is not a
  live-server end-to-end latency promise.

## Decision

Switch the house voice-embedding engine to **WeSpeaker for measured efficiency**,
not for an established accuracy gain. Keep the existing human-confirmed learning
and refusal-to-name safeguards. Do not lower naming thresholds on this evidence.

The implementation must:

1. Pin the engine, checkpoint/weight hash, library versions and embedding recipe
   in an explicit profile. Separate sample, probe and centroid caches by
   **engine/version/profile**; ECAPA and WeSpeaker vectors are incompatible and
   must never be compared, averaged or silently reused across engines.
2. Re-embed eligible **retained audio**, rebuild compatible prints and invalidate
   stale probes/guesses/validation. Do not convert old vectors or resurrect
   forgotten/discarded samples. If authorized source audio is unavailable, leave
   the affected print unavailable rather than mix profiles.
3. Calibrate and validate WeSpeaker-specific thresholds and the complete naming
   policy on separated development/held-out data. Do not blindly reuse ECAPA
   thresholds or treat these exploratory rejection results as certification.
4. Review cache migration, in-flight freshness, forgetting, failure handling,
   performance and naming-policy tests with Lume before release. Keep a
   compatible ECAPA service/profile available for rollback; rollback must restore
   compatible embeddings and calibration, or disable recognition until rebuilt.

## Consequences

Expected benefit: lower embedding CPU use and warm processing latency. Accuracy
and safe unknown rejection still need end-to-end validation on broader,
independently selected audio and unknown identities.

Only aggregate research and provenance belong in this repository. Keep speaker
names, sample identifiers, audio, vectors and per-person results private. The
linked reports/evidence remain account-authorized attachments, not public assets.
This record changes no production settings, labels, fingerprints or thresholds.

[report]: https://souls.house/api/v1/conversations/Wergmj/messages/jxyARe/attachments/3900
[bundle]: https://souls.house/api/v1/conversations/Wergmj/messages/jxyARe/attachments/3901
[profile]: https://souls.house/api/v1/conversations/Wergmj/messages/jwbAxJ/attachments/3902
[work]: https://souls.house/accounts/gNDMev/chats/vexNbJ
