# Integrated Jev → Luna: fresh Nexus check, 2026-10-01

This is an opt-in offline test of the **actual application adapter**, not a new
prototype. No historical requests were written, no production rows imported,
and no raw transcripts are published. Daniel authorised resident-message samples
from Nexus; his father's account was explicitly dropped from scope.

## Frozen candidate

- `typesafe/jev-1.13`: one response-needed question per message, threshold **0.50**.
- Only positives reach `openai/gpt-6-luna`, requested reasoning effort **low**.
- Luna receives eligible humans **and room residents**, then Rails retains only
  eligible non-author humans. Triggering-human metadata is evidence, not routing.
- Uncertainty is no verdict: preserve existing rows, clear pending, no paid loop.
- Certain negatives remove only open rows. Reply/dismissal race guards unchanged.
- Stored version: `typesafe/jev-1.13+openai/gpt-6-luna/low/reply-attention-v3`.

## Method

Seven fresh Nexus conversations, not the earlier 21 exposed examples. Sampled
up to four question-bearing and two non-question resident messages per room,
seed 119. This question enrichment is evaluation sampling, **not a production
filter**. Selected 23; excluded three **before inference** because their message
or preceding context carried sensitive collateral not needed for this check.

Labels were written before scores: 19 unambiguous human-attention labels, one
ambiguous bug report reported separately. Private labelled-input SHA-256:
`81fb4b0abb864a746e877b2490207e8839df3a9ef7542b4adc453cb9d33593e6`.

Ran `scripts/evaluate-real-reply-attention.rb` against the frozen v3 adapter,
one source message with up to four preceding context messages, and the full
resident roster of its room. Daniel is the single eligible-human fixture; this
measures attention **for him**, not correctness for every other human. Dispatch
hints were unavailable in this export and left nil. Plain structs keep the
runner out of production persistence. No tuning followed these results.

Adapter source SHA-256 (same sources used for the fresh run):

- `app/services/reply_expectation_classifier.rb`: `70d569c0826de61e261027450ad0f3d639e6371892795414ec4dad880f86766a`
- `app/services/reply_recipient_resolver.rb`: `a09818216a603b1e1a99dabda0436b3efb2e8dfa9dade0b094f59da13a298a5b`
- `app/services/utility_inference.rb`: `f5454ded2ca15927aeaaafdb05ffea2b59a060090ed9182186ee9561bd8121ba`

## Results

| Actual label | Human alert | No human alert |
|---|---:|---:|
| Request to Daniel | 2 | 0 |
| Not a request to Daniel | 0 | 17 |

**2/2 requests caught; 0/17 false alerts.** The ambiguous bug report produced no
alert and is excluded from those counts. All 20 eligible calls completed without
provider errors or uncertain outputs. Five messages passed the Jev gate and
therefore reached Luna; three of these were resident-directed exchanges, and
none incorrectly assigned Daniel. This includes the explicit resident-to-resident
review request required by Lume's scope review.

Question-enriched stratum: 2 requests and 5 non-requests, all correct.
Non-question stratum: 12 non-requests, all correct.

All individual gate scores and outcomes are in the adjacent CSV, separated by
sampling stratum. The gate score is **not** a calibrated human-recipient probability.

## Limits / merge gate

This is encouraging fresh evidence, **not a demonstrated 99% accuracy or recall**.
Only two positives remain after privacy exclusions; the nominal 19/19 must not
be presented as population reliability. One author labelled the examples; there
is no independent adjudication. Question enrichment and selected technical rooms
also make this unsuitable for a natural-traffic precision estimate.

The earlier application-shaped 6/6-positive development replay remains useful
regression evidence, not additional held-out cases. This check does not measure
all-human routing, access permissions, realistic batched live inference, latency/cost, or
provider repeatability. Unit tests cover batching, validated IDs, both payloads'
no-email metadata, uncertainty/no-loop, replies during Luna, and negative-vs-closed
lifecycle semantics. Existing cross-account integration tests cover visibility.

The model-and-effort choice remains Jev plus Luna **low**, not an extrapolation
from a different Luna effort. Costs from the earlier comparison are historical;
no new precise total-cost claim is made for this run. PR #118 stays draft pending
review and an explicit decision about the limited statistical evidence. Nothing
is merged or deployed by this evaluation.

## Additional batched synthetic regression (not held out)

After the fresh check, ran the existing 30 invented messages through the same
adapter in six five-message batches. This verifies live structured batch parsing,
but is development data and reveals **two remaining semantic errors**:

- **1/16 false alerts:** “Does anyone know which date works?” was assigned to
  Daniel rather than remaining an unassigned group question (Jev gate 0.83).
- **1/14 misses:** “Daniel, don't you want to come on Saturday?” passed Jev at
  0.92 but did not resolve to Daniel. Splitting detection/routing has therefore
  **not removed the negative-question failure** in the integrated configuration.

No uncertain outputs or transport failures. Full outcomes are in
`reply-attention-v3-synthetic-2026-10-01.csv`. These errors remain visible; the
prompt and threshold were not subsequently tuned. The fresh Nexus success does
not override these regression failures. **Quality approval is still outstanding**;
implementation review must not be mistaken for satisfying the 99% target.

## Local implementation checks

- Full Rails suite: **2,915 tests / 15,629 assertions**, no failures or errors.
- Final focused run including the additional batch/abstention case:
  **40 tests / 131 assertions**, no failures or errors.
- Scoped RuboCop: nine Ruby files, no offenses (local Ruby 4 parser compatibility
  configuration used, as in the previous PR checks).
- No frontend files changed in this revision. Earlier frontend/browser results
  and CI are historical checks, not newly rerun local results.
