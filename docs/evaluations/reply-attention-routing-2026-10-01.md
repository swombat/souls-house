# Splitting reply detection from recipient resolution

2026-10-01, follow-up to the [failed v1 evaluation](reply-attention-2026-10-01.md).
Daniel authorised resident-message samples from Nexus and his father's account.
Nexus access succeeded. No account-scoped route for the father's account is
provisioned in this resident. Daniel subsequently said to ignore that account
(message JXBGqe), so it is **excluded from scope**, not an outstanding access
request. Nothing was backfilled, merged or deployed.

## Protocol and privacy

A live development comparison on ten previously exposed examples established
that the revised questions could recover the four original missed human asks.
These are development results, not validation. One development label retained
from the human-only task incorrectly said nobody rather than a resident; that
mistake was noticed after scoring and was not silently corrected into a success.

Before Nexus inference, the prompts, 0.50 gates, requested Luna effort, selection,
and labels were frozen. Seven conversations were selected by topic, not randomly
from Nexus. Deterministic within-conversation sampling (seed 118) oversampled
question-bearing resident messages, alongside non-question messages. A question
mark in code or a URL also qualifies for this *sampling* stratum; there is no
such prefilter in production.

38 sampled messages: four collateral-sensitive examples and one machine notice
excluded before inference; **33 evaluated**. **21 were pre-labelled unambiguous**
(13 asks to somebody, eight non-asks); **12 ambiguous** cases are preserved but
excluded from accuracy. Labels are Mira's, not independently adjudicated.
The high ambiguous fraction is itself a limitation, not a hidden success rate.

Six of the 21 ask the target human; 15 do not. In the scored question-enriched
stratum there are five human asks and seven non-asks; in the non-question sample
one ask and eight non-asks. These strata must not be pooled as a population
precision estimate. The candidate roster includes two known humans and six
resident identities, rather than treating whoever last spoke as the recipient.

Private source snapshots and labels remain under Mira's
`work/reply-attention-eval/nexus/`, not in Git. No attachments or private Telegram
threads were fetched. Labels, split and expected recipients never reached either
provider. Public CSV contains pseudonymous cases/scores only (recipient ID 1 is
the target human); no transcript bodies or source conversation IDs.

Frozen label SHA-256:
`f8d25657ad24fac0bf43a531f3fde0e84dc93a68720a6ada56a95d8d3a39f146`.

## Models and decision rules

Both prototypes receive identical conversational state: current message,
authors, up to four preceding messages truncated to 1,200 characters apiece,
and the same eight-person roster. The opt-in comparison script is
`scripts/evaluate-reply-attention-routing.rb`.

1. **Jev only:** `typesafe/jev-1.13`, one general response-needed question plus
   one question per candidate, in one typed Decisions call. Both general and
   recipient scores must reach 0.50.
2. **Jev + Luna:** same general Jev gate, then `openai/gpt-6-luna`, requested
   reasoning effort **low**, strict JSON recipient IDs and an uncertainty flag,
   1,500-token output cap. `uncertain: true` means **no assignment**, even when
   IDs accompany it. Luna is run on all examples here to separate gate misses
   from attribution errors; a deployed pipeline could skip it after a negative
   gate. This trial does not establish Luna at other effort settings.

The OpenRouter catalogue and actual returned model both verified GPT-6 Luna.
No Haiku or other substitute was tested. There were no provider errors across
33 Jev + 33 Luna calls. Luna-reported cost total **$0.006617375**, median latency
**2.16s**; Jev median **0.291s**. The cost figure **excludes Jev**, whose adapter
returns scores but not usage. It is not a claim about subscription savings.

## Results: prototype and application are different evidence

| Configuration | Human TP | FN | TN | FP | Exact all-recipient sets |
|---|---:|---:|---:|---:|---:|
| Jev-only prototype | 6 | 0 | 15 | 0 | 17/21 |
| Jev + Luna prototype | 6 | 0 | 15 | 0 | 18/21 |
| Actual v2 application-adapter replay | 5 | 1 | 15 | 0 | not tested |
| Application-shaped Luna development replay | 6 | 0 | 15 | 0 | humans only |

Both prototype pipelines classify all 12 question-stratum human cases and all
nine non-question-stratum human cases correctly. Luna slightly improves the
full recipient set, but does **not** improve human attention on this sample.
It abstains on several implicit resident addressees rather than guessing.
The generic gate also suppresses an unnecessary Luna recipient suggested for a
plain acknowledgement/progress message in the development examples.

**Then we tested the actual adapter**, through
`scripts/evaluate-real-reply-attention.rb`, on all 33 examples. Its state shape
includes message IDs and a messages array; its candidate roster here is only
the target human. These are not identical inputs to the prototypes. The replay
still misses a directly addressed request to perform an upgrade: response
score **0.71**, recipient score **0.36**. Five other human asks pass, all 15
negatives remain negative; no provider errors. Question stratum: 5 TP / 7 TN;
non-question stratum: 0 TP / 1 FN / 8 TN. **Do not transfer the prototype's 6/6
claim to this adapter.** The cause of the discrepancy has not been isolated.

The candidate's live synthetic rerun passes 30/30 (14 asks, 16 non-asks), across
six batches. Those are development regression examples, not fresh validation.

## Follow-up: matched-input routing diagnosis

Eight development probes on the exposed miss varied the state representation,
full/narrow roster (including the recipient questions) and question wording.
Recipient scores ranged from 0.29 to 0.55; one combination passed the threshold.
This suggests input sensitivity but does not isolate a single causal variable or
establish deterministic scores. No threshold was retuned to count it as fixed.

We then ran **21 additional Luna calls** on the unambiguous examples using the
same application-shaped message/context/one-human state, and the recorded
application Jev general scores as gates. The routing prompt adds an explicit
rule: if the addressee is absent from the eligible list, return no assignment,
not a substitute. This is a **development replay on now-exposed data**, not a
fresh holdout. It yielded **6 TP / 15 TN / 0 FP / 0 FN**, recovering the remaining
miss. No provider errors; Luna-reported cost $0.00408045, median 1.99s. The public
CSV includes these outputs beside the original ones. The comparison evaluator
accepts explicit `state` and `precomputed_jev` for this replay only; absent those,
it retains the original prototype prompt and state.

That changes the recommendation: **Jev gate + Luna recipient resolution** is
now justified as the next candidate to build and validate, rather than assuming
Jev's recipient classification is robust enough. It does not establish 99%.

## Candidate and gate

The draft PR now contains the simpler split-question **Jev-only v2 candidate**:
one general question per message and one per eligible human, both >= 0.50,
minimum of the two scores stored. This is a decision score, **not** a calibrated
joint probability. No automatic assignment to the last/triggering human and no
Luna production dependency. Dispatch-user metadata can be evidence later, not
an authoritative recipient: some messages lack the dispatch link, while others
are residents asking residents despite a human starting the turn.

**PR remains draft.** Even the perfect prototype sample cannot establish 99%
quality; the application replay still has a concrete miss. The next work is to
isolate state/roster sensitivity, validate real cross-account human routing,
and review labels. The father's-account sample is explicitly out of scope. Nexus data
already exposed during this comparison can be development data but cannot be
reused as a fresh holdout. Full production-burst and multi-human validation are
also still outstanding. No broad transcript sweep is authorised or needed.


## Proposed next adapter (scope review, not implemented)

- Keep the typed Jev **general** response-needed decision batched across new
  messages; retain 0.50 as the current development threshold.
- For messages passing it, make one bounded, structured GPT-6 Luna call (low
  effort) over those messages, eligible humans and conversational context.
  Known speaker identities may be context, not automatically eligible recipients.
- Return exact message IDs and eligible recipient IDs, with per-message
  uncertainty. Validate every ID and duplicate. Rails still owns current access,
  self-exclusion, reply/dismissal cutoffs and writes.
- No automatic last-human or triggering-human assignment. A dispatch user can
  be an explicit contextual hint where available, never a fallback obligation.
- A certain empty recipient set is a negative verdict. An uncertain result is
  **not** one: omit that message's verdict so existing expectations are preserved,
  just as the current job preserves skipped oversized input. Never clear on a
  malformed/provider-error result; use the existing bounded retries.
- Version the model/prompt/decision policy; record a Jev response score as such,
  not a fabricated Luna confidence. No wake or notification change, no backfill.

Lume is asked to review this narrow scope change before replacing the candidate
with the two-model adapter. The experimental Jev-only v2 remains on the draft
branch, explicitly not merge-ready.
