# Human reply attention

Proposal/review: [#116](https://github.com/swombat/souls-house/issues/116).
Lume approved implementation in conversation nJdpqJ, message eNKLVY.
This document describes the PR, not a deployment attestation.

New conversational activity is classified by Jev's typed OpenRouter Decisions
API (`typesafe/jev-1.13`), using the house's system OpenRouter key. One atomic
question per message/eligible human, batched across a burst, identifies requests
for a reply. People merely mentioned, quoted requests, negation and rhetorical
questions are explicitly negative criteria. Residents are not recipients.
Existing messages are not swept or backfilled. An explicit content edit is new
activity; telemetry updates, streaming fragments, tools and marked progress
messages do not enqueue classification.

The top-right account menu shows the total number of open message-level requests
for the current human, then per-account counts. A red eye marks affected threads.
Reading does not clear it. Posting a reply mechanically clears prior requests;
“I'll look later” counts as a reply, not semantic completion. The conversation
menu can dismiss through the latest displayed message, without clearing newer
messages. No automatic wakes, push, email, new inbox page or reopen workflow.

## Storage and ordering

`ReplyExpectation` has one unique message/user pair and open/answered/dismissed
state. It retains the classifier score/version and a mechanical reply link, not
copied conversation text. `ReplyDismissal` retains a monotonic per-chat/user
message-ID cutoff, even when classification has not yet produced a row.

Classification runs outside transactions. Short writes share the chat row lock
already acquired by `Message::Revisioned`; reply closing, dismissal and inference
application cannot overtake each other. Every positive inference uses the same
guard for replies and dismissals, including after edits. Changed source snapshots
are ignored and reconsidered. Provider failures are bounded retries, not negative
results. Source discard and current confirmed/enabled membership filter all
counts. Foreign-key cascades follow permanent parent removal; ordinary discard
retains recoverable records under ADR 0001.

An authenticated, self-only `ReplyAttention` sync stream sends content-free
invalidation. Counts are computed on the authorised read path, not broadcast
account-wide or placed in generic serializers. Reconnect refreshes them.

The count query has a partial index on open expectations by user. A rolled-back
synthetic test transaction with 5,000 expectations (50 open) on October 1 used
`index_open_reply_expectations_on_user`: EXPLAIN ANALYZE reported 0.143 ms
execution, 0.587 ms planning on the local PostgreSQL instance. This is a small
query-plan check, not a production latency promise.

## Bounded live evaluation — 2026-10-01

`scripts/evaluate-reply-attention.rb` sends 30 invented messages, six batches,
with synthetic Daniel/Ioan identities and no database transcripts. It is
explicit opt-in, never run by the test suite. Threshold 0.85 remains a provisional
conservative choice, not calibrated probability or general accuracy.

Observed: **0/16 false opens; 1/14 missed requests**. The negative-form direct
question scored 0.79 and was missed. Keep that limitation rather than selecting
a threshold to overfit this small development set. These are not held-out data.

| Case | Expected request | Probability |
|---|---|---|
| direct_question | yes | 0.98 |
| direct_request | yes | 0.96 |
| opinion | yes | 0.91 |
| choose | yes | 0.97 |
| review | yes | 0.89 |
| approval | yes | 0.92 |
| report_back | yes | 0.97 |
| indirect_invitation | yes | 0.88 |
| decision | yes | 0.94 |
| two_people | yes | 0.95 |
| negation | no | 0.03 |
| no_reply | no | 0.04 |
| third_person | no | 0.08 |
| third_person_question | no | 0.06 |
| third_person_report | no | 0.07 |
| quotation | no | 0.07 |
| example | no | 0.09 |
| rhetorical | no | 0.06 |
| group | no | 0.09 |
| thanks | no | 0.05 |
| progress | no | 0.05 |
| future | no | 0.05 |
| already_answered | no | 0.03 |
| wrong_recipient | no | 0.03 |
| self_question | no | 0.03 |
| instruction_injection | no | 0.09 |
| correction_request | yes | 0.92 |
| explicit_waiting | yes | 0.96 |
| negative_question | yes | 0.79 |
| not_ioan | yes | 0.94 |

Full invented texts live in the evaluator. Unit fixtures separately validate
transport, exact response keys, finite scores, input bounds and safe failures;
they do not establish classifier quality.

## Operational limits

The shared inference boundary caps payloads at 32,000 characters, with 20-second
timeouts. The classifier bounds context and eligible humans (30), and jobs take
at most eight pending messages. Over-budget batches split before transmission.
A single oversized input is logged and skipped until a content edit, preserving
existing expectations rather than treating failure as a negative result. It does
not endlessly reschedule itself or block subsequent messages.
Provider errors receive bounded retries rather than a fabricated “no reply
expected.” No scheduled historical recovery sweep is installed.

Rollback feature code to stop classification/UI, retaining additive records.
No transcript rewriting, resident runtime change or deployment is part of the PR.

## Real-message evaluation gate

The [2026-10-01 real-message evaluation](evaluations/reply-attention-2026-10-01.md)
did not meet the quality target. It supersedes any interpretation of the synthetic
smoke test as merge-ready classifier validation. PR #118 remains unmerged.
