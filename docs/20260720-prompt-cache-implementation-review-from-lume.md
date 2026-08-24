# Review: prompt cache prefix stability + conversation compaction

Date: 2026-07-20
Reviewer: Lume
Reviewing: commit a6d90f0 ("Stabilize inline agent prompt caching") + the
uncommitted compaction work (ConversationCompaction, retrieval tool, timeline
card, telemetry)
Requirements: `docs/requirements/20260719-inline-agent-prompt-cache-prefix-stability.md`

## Verdict

The architecture is right and the implementation is faithful to the
requirements — in several places better than the spec (the activation-boundary
split handles group-chat tails more correctly than my sketch; the compaction
record with per-compaction telemetry and the retrieval tool referenced from
inside the checkpoint text close loops the requirements only gestured at; the
paired VCR cassettes are exactly the load-bearing tests, really recorded).

Two findings, however, would silently eat much of the economic win. Both are
small fixes. Nothing here needs an architectural change.

## Finding 1 — HIGH: post-compaction sliding window breaks prefix stability

The interaction:

1. `ConsolidateConversationJob#perform` consolidates through `messages.last` —
   the boundary is the newest message at job time, so immediately after
   compaction **zero** messages sit beyond the boundary.
2. `Chat::Contextualizable#context_messages_for` re-includes the last
   `RECENT_TRANSCRIPT_MESSAGES` (20) via a **read-time** window:
   `recent_ids = context_messages.last(20)`.
3. That window slides on every new message. For the ~20 turns after a
   compaction, the oldest included pre-boundary message drops off the front
   of the transcript **each turn**.

The changed bytes sit immediately after the checkpoint block — ahead of
essentially the whole transcript. Every one of those turns invalidates the
cached prefix and pays a full cache **write** (2× at the 1h TTL) with no
read. The worst cost mode lands precisely on the chats compaction targets,
and the telemetry will show healthy-looking cache *writes* while money burns.

**Fix (also a simplification):** enforce the floor at consolidation time, not
read time:

- `messages_to_consolidate` drops the newest `RECENT_TRANSCRIPT_MESSAGES`
  from its result (and the job returns early if nothing remains);
- `context_messages_for` reduces to `id > last_consolidated_message_id` —
  delete the `recent_ids` logic;
- same deletion in `ConsolidateConversationJob.transcript_token_count`, which
  currently duplicates the selection logic (drift risk lives there too).

The boundary is then fixed between compactions and the transcript is
append-only by construction — which is the whole point of the design.
Requirement 3.5's "recent exchange travels verbatim" still holds, now by
construction rather than by a moving window.

Provenance note: this defect traces to my requirements, not to your reading
of them. Requirement 3.5 specified a floor ("never truncate below the last N
messages") without saying where it must be enforced, and the read-time
implementation is the natural reading of my sentence. The spec's ambiguity
seeded the bug; the fix above is where the requirement should have put it.

## Finding 2 — MEDIUM-HIGH: v1-layout Anthropic agents now pay the 1h write premium every turn

`build_legacy_context_for` also routes the transcript through
`LlmPromptCachePolicy.transcript_messages`, so v1 agents (the default —
`prompt_cache_layout_v2` defaults to false) get the tail breakpoint at 1h
TTL. But their dynamic system block still changes on every activation *ahead
of* the transcript, so across-turn cache reads remain impossible for them.

Net effect for a v1 Anthropic agent on a non-tool-loop response: ~2× write
premium on nearly the whole prompt, every turn, with reads only inside
tool loops. Until agents are flipped to v2, this plausibly *increases*
Anthropic spend fleet-wide.

**Fix options (either is one conditional):**

- (a) annotate the transcript tail only when `agent.prompt_cache_layout_v2?`;
- (b) TTL by layout: `5m` for v1 (tool rounds are seconds apart, so the
  intra-response benefit survives at a 1.25× premium), `1h` for v2.

I lean (b) — it keeps the tool-loop win for un-migrated agents — but (a) is
the more conservative default. Either way: flip Ioan's agents to v2 promptly;
they are the motivating case and the v2 path is where the measured 86%
within-1h pacing pays.

## Finding 3 — LOW-MED: over-budget sweep prefilter compares bytes to tokens

`ConsolidateStaleConversationsJob#over_budget_conversations`:

```ruby
.having("SUM(OCTET_LENGTH(...)) > ?", ConsolidateConversationJob.transcript_budget_tokens)
```

Bytes on the left, a token count on the right. Over-inclusive by roughly 4×
(safe direction — nothing is missed), but it means every sweep then runs the
expensive Ruby-side token count (which loads *all* of a chat's messages) on
chats that are ~4× under budget. Multiply the threshold (`* 4` with a comment
naming the bytes≈4×tokens heuristic), and consider whether
`transcript_token_count` needs `includes(:user, :agent)` at all — it only
touches names and content.

## Finding 4 — LOW: non-agent chats can be compacted but never consume the checkpoint

`eligible?`'s over-budget arm is not conditioned on `group_chat?`. Regular
model chats (no agents) can therefore get a checkpoint summarized and stored
— but their send path doesn't go through `build_context_for_agent`, so the
checkpoint is never used for truncation: one Sonnet call of cost, zero
benefit, per such chat. **[verify]** that regular chats really bypass the
truncating path — if I'm right, either scope the over-budget trigger to
chats with agents, or (the bigger prize, separate piece of work) wire
checkpoint truncation into the regular chat completion path too: the Nexus
account is 200M input tokens, an order of magnitude above the account that
motivated all this.

## Minor notes

- `prompt_timezone_for` performs `update_column` inside the context-build
  read path. Works, but a write-on-read will surprise anyone running context
  builds against a replica or in a test that expects no writes. Consider
  pinning at chat creation / first message instead.
- `checkpoint_context_message` embeds the boundary message's timestamp; if
  that message is ever hard-deleted, the checkpoint block's bytes change and
  the prefix rolls once. Acceptable; noting for telemetry-reading sanity.
- First compaction changes the tool set (retrieval tool appears), which
  rolls the Anthropic cache once. It coincides with the compaction roll, so
  fine — but worth remembering when a cache-read dip shows up in telemetry.
- Repeated re-summarization folds the previous checkpoint into the next
  (chain compression). Inherent and fine at the 2k target; the compaction
  records preserve the full chain for audit, which is nice.
- The paired-cassette assertions use `> 1_024` as the minimum-prefix guard;
  Opus's floor is 4_096. Harmless — the cassettes are recorded reality and
  show actual reads — but the constant understates what the test proves.
- I could not run the suite locally: Ruby 4.0.2 + vcr 6.3.1 fails at boot
  (`CGI.method(:parse)` NameError — cgi slimmed in Ruby 4). Pre-existing
  environment issue, not this change. Please confirm green in your
  environment/CI and consider pinning the `cgi` gem so reviews can run tests
  here.

## What's notably good

- Trust-delegation paragraph in the stable kernel, verbatim from spec, and
  the envelope self-identifies and closes with the "respond to the
  conversation, not this block" line.
- The activation-boundary split (`rindex` of last human message) is a more
  correct reading of "envelope before the newest human message" than my
  spec, and handles agent-initiated activations (boundary nil → envelope
  last) cleanly.
- Deterministic ordering fixes landed everywhere flagged (participants both
  sides, `order(:id)` on users, whiteboard index without char counts in the
  envelope).
- Timezone pinned per chat (modulo the write-on-read note above).
- Telemetry: layout version, component bytes, stable-block sha256 — exactly
  what makes future cache misses explainable in one query.
- The compaction UX loop: timeline card + retrieval tool + the checkpoint
  text telling the agent the tool exists. The agent is told what it no
  longer knows and how to get it back. That's the right shape for memory an
  agent can trust.

## Suggested order of remaining work

1. Finding 1 (before the compaction work is committed — it changes job and
   read-path behavior together).
2. Finding 2 (one conditional; decide (a) or (b)).
3. Flip Ioan's agents to `prompt_cache_layout_v2` and re-run the Stage 0
   queries after a few days of real use — target from the requirements:
   cached share of input >60% on account 6.
4. Findings 3–4 and minor notes as cleanup.
