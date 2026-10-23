# WeSpeaker policy calibration — 2026-10-23

Issue #504: development-only empirical translation, not a new engine benchmark
or a statistical safety guarantee.

## Selected constants

| Policy | ECAPA baseline | WeSpeaker |
|---|---:|---:|
| Absolute cosine threshold | 0.55 | **0.55** |
| Winner minus runner-up margin | 0.15 | **0.15** |
| Duplicate-claim split threshold | 0.75 | **0.764** |

Keep existing **per-account held-out validation**, account/cohort activation
gates, and **person-confirmed suggestions**. These constants do not authorise
automatic identity assignment or bypass any existing validation.

## Inputs and leakage boundary

Read the existing frozen protocol, split definitions and scoring implementation
before calculating scores. Validate the unchanged v2 split by recomputing it from
manifest metadata. Use only globally assigned **development** sessions and
exclude the unknown-test identity cohort even when its clips have development
session roles. Enrollment and test embeddings/results are not loaded.

Support: **80 development clips, 27 people, 8 session groups**. Only **7 people**
have cross-session positive pairs. Every pair has different session groups;
same-source and content-duplicate checks are inherited from the frozen scorer.
No audio, external calls, new extraction, score-based split changes or identity
selection are used.

Load individual development cache entries by recomputing the runner's cache key
from manifest content metadata and pinned run configuration. Validate cached
content, span, model and extraction success. Do not open the combined result
files, which also contain holdout vectors. Compare the existing production
10-second-window ECAPA diagnostic with whole-clip WeSpeaker on identical clips.
Each clip vector is L2-normalized by the existing scorer.

## Selection rule and results

Use every unordered cross-session development pair, separating same-person and
cross-person pairs. Choose the lowest nonnegative **0.001 grid** absolute
threshold **at least 0.55** whose impostor acceptance count does not exceed
ECAPA at 0.55. The floor follows ADR 0006's instruction not to lower naming
thresholds on this evidence; it is an explicit conservative policy choice, **not
an assertion of cross-model numeric threshold equivalence**.
Equal-score blocks are never divided. The largest development impostor cosine
is 0.512842 for ECAPA and 0.503699 for WeSpeaker; upward grid rounding gives
0.504 without the floor. That unsmoothed near-maximum estimate is **not chosen
for rollout**: it puts a tight boundary around a tiny observed sample rather
than providing a confidence-bound buffer. The selected floored value is 0.55.

For margins, each directed anchor is paired with one same-person reference and
one different-person reference, both from sessions different from the anchor.
Enumerate all such two-reference trials. A wrong-claim margin is impostor cosine
minus genuine cosine. Select a grid margin meeting the ECAPA 0.15 wrong-margin
count ceiling, with a **conservative policy floor of 0.15**. Also require joint
absolute-plus-margin wrong claims not to exceed the baseline count.

Both engines have zero wrong-margin trials even at zero margin. Consequently
these data **cannot identify a necessary positive margin** or establish
cross-model numeric margin equivalence. Retaining 0.15 is an explicit conservative
policy choice, not a fitted optimum or grounds for removing the margin gate.

Choose split threshold from the same-person cross-session cosine distribution:
the lowest grid value, at least the selected main threshold, accepting no more
positive pairs than ECAPA at 0.75. This produces 0.764 and deliberately retains
the baseline's restrictive observed duplicate-claim acceptance.

| Development outcome | ECAPA | WeSpeaker |
|---|---:|---:|
| Cross-person pairs above main threshold | 0 / 1,828 (0%) | 0 / 1,828 (0%) |
| Same-person pairs above main threshold | 15 / 19 (78.95%) | 18 / 19 (94.74%) |
| Same-person pairs above split threshold | 3 / 19 (15.79%) | 3 / 19 (15.79%) |
| Wrong margin-only trials | 0 / 1,961 (0%) | 0 / 1,961 (0%) |
| Wrong absolute-plus-margin trials | 0 / 1,961 (0%) | 0 / 1,961 (0%) |
| Correct absolute-plus-margin trials | 1,558 / 1,961 (79.45%) | 1,857 / 1,961 (94.70%) |

Compared with the unselected 0.504 estimate, the 0.55 policy floor reduces
WeSpeaker genuine pair acceptance from 19/19 to 18/19 and correct joint
two-reference trial acceptance from 1,960/1,961 to 1,857/1,961. Impostor and wrong
joint counts remain zero; the 0.15 margin floor and 0.764 split policy are unchanged.

Correct-claim margin minimum / median / maximum:

* ECAPA: 0.025911 / 0.592269 / 0.956812.
* WeSpeaker: 0.129839 / 0.631955 / 1.062836.

Same-person cosine minimum / median / maximum:

* ECAPA: 0.524472 / 0.627781 / 0.786784.
* WeSpeaker: 0.531967 / 0.719390 / 0.814165.

## Reproduction and audit

Set `BENCHMARK` to the existing private benchmark directory, outside the
repository. The command creates an aggregate-only artifact inside that
directory's `calibration/` subdirectory, using exclusive creation; it will not
overwrite an existing run. A second reproduction can use a private copy of the
benchmark metadata and development caches with an empty calibration directory.

```sh
python3 scripts/voice-calibration/calibrate.py --benchmark "$BENCHMARK"
VOICE_BENCHMARK="$BENCHMARK" python3 -m unittest discover \
  -s scripts/voice-calibration -v
```

Without `VOICE_BENCHMARK`, CI runs the six self-contained numeric/pair-policy
tests and explicitly skips four integration audits of the external frozen
scorer. The full ten-test receipt below used that scorer locally.

The script emits only aggregates. Input errors are deliberately generic because
upstream validation messages may include private identifiers. Synthetic audits
cover unchanged split validation, development-only role and identity selection,
source/content leakage refusal, opening only selected cache entries, extraction
failure refusal, cross-session pair counts, engine pairing, grid rounding/ties,
absolute and margin floors, joint ceiling, split conservatism and insufficient
support. Final receipt: **10 calibration tests, 19 existing scorer tests and 9
existing cross-validation tests passed**. The final aggregate artifact is
`calibration/policy-summary-v4.json`; earlier drafts are not rollout selections.

## Policy limitations

* This is a post-benchmark development calibration, not the original frozen
  open-set tuning objective. No holdout scores were consulted to choose it.
* Nineteen genuine pairs from seven people are sparse. Pair and trial counts
  share people, sessions and audio; they are **not independent trials**.
  Zero observed impostor acceptance is not an error bound or certification.
* These are clip-to-clip cosines and two-reference margin trials, not the full
  production gallery of normalized mean voiceprints. Different gallery sizes,
  one-print cohorts (runner-up zero), unknown identities and changing accounts
  can behave differently. Existing per-account validation remains essential.
* Cross-recording positive pairs proxy the split score scale; they do not test
  actual same-recording diarization fragmentation or the joint event that all
  duplicate claims pass. Split calibration is especially weak at this size.
* The source collection was ECAPA-screened before human confirmation.
  Confirmation does not remove selection bias. Coverage omits recording-backed
  references inaccessible to the benchmark and does not evaluate recognition
  of the account owner's absent references.
* No new untouched test evaluation or deployment-wide winner claim is made.
  The constants satisfy the stated **empirical relative** criteria on available
  development support only. A stronger risk claim needs more independent data.
