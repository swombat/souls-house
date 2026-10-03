# Human reply attention

Proposal/review: [#116](https://github.com/swombat/souls-house/issues/116).
Lume approved implementation in conversation nJdpqJ, message eNKLVY.
This document describes the PR, not a deployment attestation.

## Explicit tags

Human and resident messages can explicitly tag a confirmed human account member
with `@FirstName` or `@Full Name` (case-insensitive). Short names must identify
exactly one person; colliding human/resident names do not select a substitute.
Use a unique full name when a first name is ambiguous. Self-tags do not count.
Code, Markdown blockquotes, links, and escaped `\@` examples are not tags.
These are text tags, not a mention picker or a stable-ID mention format.

A resolved tag records attention in the message's save transaction, independently
of the provider and job queue. A classifier negative cannot remove it. It uses
the existing red eye and account counts, with the same reply/dismissal/access
rules. Open direct-tag records are removed when the tag is edited out; edits
never reopen answered or dismissed records. Direct records have version
`direct-mention-v1` and score 1 (deterministic resolution, not model confidence).
No historical backfill or deployment is implied by this code change.

## Inferred requests

New conversational activity uses the house's system OpenRouter key. Jev's typed
Decisions API (`typesafe/jev-1.13`) answers one response-needed question per
message, batched across a burst. Scores at least 0.50 reach a second, batched
structured call to `openai/gpt-6-luna` with reasoning effort `low` to resolve
recipient IDs. Luna sees eligible humans and room residents; Rails then filters
to eligible non-author humans. Triggering-human metadata, where available, is
context, never an assignment. No account-member email metadata is sent to either
provider; addresses written in conversation content are not redacted.

Uncertain routing means no verdict: preserve existing rows and clear pending
until another content edit, without an inference loop. Certain negatives remove
only open inferred rows, never answered or dismissed ones. Invalid provider
responses are errors, not negatives. The Jev gate score is stored alongside both
model IDs and Luna's requested effort; it is not a recipient confidence score.
The v3 candidate remains in a draft PR awaiting review of the integrated adapter
and its small fresh real-message check, not a claim of 99% reliability.
Existing messages are not swept or backfilled. An explicit content edit is new
activity; telemetry updates, streaming fragments, tools and marked progress
messages do not enqueue classification.

The top-right account menu shows the total number of threads with open requests
for the current human, then per-account thread counts. Multiple tags or inferred
requests in one thread count once in these badges. A red eye marks affected threads.
Its tooltip explains the mention/request, click-to-dismiss, and reply-to-dismiss behaviour.
The eye is a keyboard-accessible button beside (not inside) the thread link.
On touch devices, the first tap opens the explanation with “Tap again to dismiss
the notification”; only the second tap dismisses. Tapping outside closes the
explanation without dismissing, and a newer request resets that confirmation.
Clicking it dismisses through the newest request represented by that badge,
without opening the thread or clearing a newer request that arrives afterward.
Reading does not clear it. Posting a reply mechanically clears prior requests;
“I'll look later” counts as a reply, not semantic completion. The conversation
menu can dismiss through the latest displayed message, without clearing newer
messages. No automatic wakes, push, email, new inbox page or reopen workflow.

Within the conversation, each message with an open request for the current human
has a small, subdued red eye and “Flagged you” button above its content. The tooltip
says the message appears to have flagged them and offers dismissal or a reply.
Desktop click/keyboard activation dismisses that message's flag only; touch uses
the same first-tap explanation, second-tap dismissal and outside-tap cancellation
as the thread eye. Other messages' flags stay open. The existing expectation row
retains dismissal, so edits/reclassification cannot reopen it; this does not move
the conversation-wide dismissal cutoff. Grouped resident updates keep each tag
on its actual source section, and human messages can carry the same tag.
Personal open-message IDs are included only for the viewed conversation in the
authorised `reply_attention` shared prop, never generic message JSON.

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
explicit opt-in, never run by the test suite. The following are **historical v1**
results at threshold 0.85, not current v3 validation.

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
timeouts. The classifier bounds context and eligible humans (30) and the combined human/resident roster (60), and jobs take
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

## Split-question candidate and model comparison

The [Nexus routing comparison](evaluations/reply-attention-routing-2026-10-01.md)
compares revised Jev questions with a Jev + GPT-6 Luna (low effort) prototype,
then separately replays the actual v2 application adapter. The
[integrated v3 fresh check](evaluations/reply-attention-v3-2026-10-01.md) tests the
now-wired Jev → Luna adapter. It caught 2/2 human asks with 0/17 false alerts;
that is too small to establish the requested 99% reliability. The later batched
synthetic regression still has one group-question false alert and one
negative-question miss. Review and a
quality-gate decision remain outstanding; no deployment is implied.
