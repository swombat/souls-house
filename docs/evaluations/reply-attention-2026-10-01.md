# Real-message evaluation: merge gate not met

2026-10-01, production classifier at `7f503e96`, Jev 1.13 typed Decisions
API through OpenRouter. No historical attention records were created.
The synthetic smoke test is **not** evidence of 99% real-message quality.

## Sampling and labels

150 messages from eight authorised conversations in the requesting account,
selected as a bounded convenience sample of development discussions. No Nexus
messages were sent. This is not representative of social conversation or of
another account's requests. Recipient: the requesting human only. External
resident accounts were treated as resident authors, not extra human targets.

Mira labelled before inference; no independent human adjudication. Three
conversations (75 messages) were tuning, five (75 messages) held out. Whole
conversations were separated, but related topics and author style still overlap.

- 49 self-authored messages excluded from inference (the production self filter).
- 1 system notice excluded.
- 3 ambiguous cases identified **before** scoring and excluded from metrics,
  but still evaluated and reported separately.
- 97 scored cases: 93 negatives and **only four positives**.

Labels frozen under SHA-256
`66dd51349124e6cdaddfab9cb405a23b518ef29f8dcee7354af583b0dda7778f`.
Private source snapshots, labels/reasons, original scores and the threshold
selection record remain in Mira's `work/reply-attention-eval/`, not Git. The CSV
beside this report publishes every probability without transcript content or
conversation identifiers.

Each call used the actual `ReplyExpectationClassifier`, one source message and
its preceding four messages (the production 1,200-character context limit).
Only conversational content/author metadata and recipient ID/name were sent;
labels, expected answers and split names were not supplied to Jev. No attachments
were downloaded. This tests the single-message path, not burst/batch sensitivity,
multiple recipients, lifecycle races, or live account membership resolution.
The opt-in script `scripts/evaluate-real-reply-attention.rb` preserves this shape
using plain structs, never production message imports or expectation writes.

## Tuning, then a single held-out test

At the original 0.85 threshold, both tuning asks scored **0.78** and were missed;
all 48 negatives were correctly rejected (highest negative: 0.24). These asks
requested a browser diagnostic and a report back without naming the recipient.

A candidate threshold of **0.75**, with the semantic prompt unchanged, was
recorded **before** held-out inference. It would correctly classify 50/50 tuning
cases on the already recorded scores. No repeated calls were needed for that
threshold comparison.

| Partition / threshold | TP | FN | TN | FP | Accuracy | Request recall |
|---|---:|---:|---:|---:|---:|---:|
| Tuning, original 0.85 | 0 | 2 | 48 | 0 | 96.0% | 0/2 |
| Tuning, candidate 0.75 | 2 | 0 | 48 | 0 | 100% | 2/2 |
| Held-out, candidate 0.75 | 0 | 2 | 45 | 0 | 95.7% | 0/2 |

Held-out misses:
- A blocked implementation handed back to the human for applying a patch or
  granting write access: **0.49**. This label uses the product's action-and-report
  interpretation; it is less explicit than a direct question and merits review.
- An explicit short question following an offer to draft a patch: **0.71**.

The three pre-labelled ambiguous cases scored 0.17, 0.10 and 0.05; none triggered.
All **100 external calls** returned valid scores; no provider errors or retries.
The recorded held-out scores would also miss both asks at the original 0.85.

## Decision and limits

**Do not merge on a 99% claim.** The candidate did not pass the holdout, so the
application threshold remains 0.85; the experimental lowering was reverted.
Zero observed false alerts among 45 held-out negatives does not establish a
population false-alert rate below 1% (even under an unrealistic independent-sample
assumption, the one-sided 95% upper bound is approximately 6.4%). Precision is
undefined because the held-out classifier emitted no positive decisions.

The data suggest difficulty with context-addressed asks, not proven causation.
No-name requests and offers should be part of the next prompt/calibration work.
That work may reuse this now-exposed sample for development, but any new quality
claim needs a **new** frozen holdout with more real positive examples and reviewed
labels. Do not relabel misses, tune further on this holdout, or count self-filtered
messages as classifier successes to reach the target.
