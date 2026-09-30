# Inline-agent caching: response and sharpened direction

Date: 2026-07-19
Author: Lume
Status: response to `inline-agent-prompt-caching-and-continuity-2026-07-19.md`

The analysis doc is right about the architecture: mutable continuity serialized
before append-only history is the structural defect, and the tail-envelope
layout is the correct fix for it. I agree with the staged path. But the doc has
one significant blind spot and underweights one lever, and both change what to
do first. This response covers those, adds volatility bugs found by reading the
actual code, and answers the eight open questions.

## 1. The blind spot: cache TTL vs conversation pacing

The doc never mentions TTL. The July 14 hosted-agent economics doc did this
math for Chaos — 5-min default TTL, 1h extended at 2× write cost, reads refresh
the TTL, 55-minute wakes chain across the day — but the inline doc doesn't
import it, and it is decisive.

**A perfect prefix layout produces zero cache reads if the next turn arrives
after the TTL expires.** Human-paced chats — Daniel's dad's usage specifically —
have inter-turn gaps measured in minutes to hours. For any gap beyond the TTL,
the proposed re-architecture doesn't just fail to help; it *costs more* than no
caching (1.25–2× write premium, never read).

So there are two distinct cost regimes, and the doc conflates them:

| Regime | Examples | What fixes it |
|---|---|---|
| **Fast turns** (< TTL apart) | tool loops within a response; `AllAgentsResponseJob` fan-out (N agents answering the same message within minutes); rapid back-and-forth; initiation cycles paced under 1h | prefix-stable layout + correct breakpoints (the doc's plan) |
| **Slow turns** (> TTL apart) | dad-style long chats over days; sparse proactive initiations | **nothing about caching helps. Only bounding the transcript helps.** |

The dad-cost driver is almost certainly the slow regime: a long transcript
re-sent in full, uncached, every turn — O(n²) cumulative input cost in message
count, and no cache architecture bounds n.

**Cheapest possible first move, before any telemetry work:** one SQL query over
existing message timestamps. For the expensive chats, compute the distribution
of gaps between consecutive agent responses. That single number — what fraction
of turns land inside a 5-minute / 1-hour window of the previous turn — tells us
which regime dominates and therefore whether the envelope re-architecture or
transcript bounding is the urgent fix. No new instrumentation needed; the data
is already in `messages.created_at`.

## 2. The missing option: transcript budget + checkpoint summarization

The doc's option list has no answer for the slow regime. The answer is the one
every long-running agent harness converges on: a rolling context window.

- Define a per-chat transcript token budget.
- When exceeded, run a checkpoint job: summarize the oldest messages into a
  persisted checkpoint block (stored, auditable, versioned).
- Prompt becomes `[kernel][checkpoint][recent transcript][envelope][new msg]`.
- The checkpoint changes rarely (only at re-checkpointing), so it sits inside
  the stable cached prefix.

This bounds per-turn cost regardless of pacing, which caching never does. It
composes cleanly with the tail-envelope layout rather than competing with it.
And it is the inline twin of what already exists: hosted Chaos sessions
compact, and today's close-conversation / leave-conversation work is the
*social* version of the same cost-bounding move. HelixKit keeps arriving at
"the context must stop growing" from different directions; this is that,
applied to the inline prompt.

Checkpoint boundaries should align with cache breakpoints so a re-checkpoint
rolls the cache exactly once, amortized over the turns it saves.

## 3. The underweighted lever: Anthropic allows four breakpoints, we use one

`LlmPromptCachePolicy` currently marks only the stable identity block. Two
consequences:

1. **The tail-envelope layout pays off on Anthropic only if a second
   breakpoint rides the tail of the transcript.** Mark the last transcript
   message (before the envelope) with `cache_control`. Turn N writes the cache
   through the end of its transcript; turn N+1's prefix matches through that
   point, reads it, and pays write only for the delta (turn N's response + new
   envelope + new message). Without this, moving the envelope to the tail
   improves nothing on Anthropic — the only marked prefix is still just the
   kernel. This is the difference between caching ~2k tokens and caching the
   entire conversation.

2. **Minimum cacheable prefix length (1024 tokens on most models, 4096 on
   Opus) means today's stable-block caching is likely a silent no-op for any
   agent whose `system_prompt` is short.** Worth checking against real agents
   before trusting any telemetry that says "caching is on." A tail-of-transcript
   breakpoint mostly dissolves this problem because the whole prefix counts
   toward the minimum.

Suggested breakpoint scheme (within the 4-breakpoint limit):

```text
bp1: end of stable kernel (+ stable per-chat block, see §5)
bp2: end of checkpoint block, when present
bp3: end of transcript (moves forward each turn)
```

Note an unknown to verify: whether RubyLLM supports `cache_control` on
non-system messages on the inline path. If not, that's the upstream patch that
matters most.

TTL should be configurable per deployment as it already is for Chaos
(`CHAOS_ANTHROPIC_CACHE_TTL=1h` precedent) — 5-min TTL dies in human-paced
gaps and its writes are pure waste there.

## 4. Additional volatility bugs found in the code

Beyond the doc's audit, reading `Chat::Contextualizable` surfaced these:

- **The 6-hour sliding window churns from pure time passage.**
  `other_conversation_summaries` filters `chats.updated_at > 6.hours.ago`, so
  a conversation drops out of the list when it *ages*, with no state change
  anywhere. Byte-divergence on a timer. Fix: quantize the window boundary
  (e.g. evaluate at hour granularity) or, better, make list membership an
  explicit revisioned state updated by jobs rather than a query-time window.
  (Moot once summaries live in the tail envelope, but worth knowing.)
- **`participant_description` plucks without ordering** — both the humans list
  and the agents list. Nondeterministic byte order confirmed, not just
  suspected.
- **The whiteboard index embeds `content.to_s.length` for every board**, so
  editing *any* board invalidates the block even for agents that never touch
  it. Revision numbers alone would carry the same information.
- **Transcript timestamps render in `recent_user_timezone`** — the timezone of
  the most recent posting user's profile. If that flips (travel, or a
  different-timezone user posts), **every timestamp in the entire transcript
  rewrites**, invalidating the whole history in one stroke. Rare but
  catastrophic for prefix reuse. Pin the rendering timezone per chat, or per
  message at write time.
- One-shot borrowed context and initiation reasons currently cause divergence
  twice: once appearing, once disappearing. They belong in the envelope, where
  appearance and disappearance are free.

## 5. Where the current dynamic sections should land

Three destinations, not two:

**Stable per-chat block (system role, under bp1, changes ~never):**
agent-only-thread warning, development-mode warning, voice instructions, the
group-conversation statement. These are behavioral instructions that want
system authority, and they are near-constant for the life of a chat. When one
does change, eat one cache roll — fine.

**Tail envelope (per-activation, never cached, cheap to vary):**
current time (minute precision is fine *here* — position was the problem, not
granularity), cross-conversation summaries, memory/continuity cues, health
one-liner, whiteboard index (names + revisions, no char counts), participants,
conversation title, initiation reason, borrowed context.

**Tools (deep detail, on demand):**
full active whiteboard contents (the largest and most volatile block in the
current prompt — the envelope carries "active board: project-plan, rev 12" and
the existing whiteboard tool carries the bytes), full memory archive, full
health data, full other-chat transcripts (the borrow_context tool already
exists).

This is the doc's Option 5, with the amendment that the "active whiteboard
contents" section — currently injected wholesale — is the single biggest win
from demotion to a tool + revision cue.

## 6. Answers to the eight open questions

**Q1 — Is a trusted tail envelope authoritative enough?**
Yes, with one move: the stable kernel *delegates trust* to it. Add to the
kernel: "Each activation ends with a `<helixkit_context>` block. It is
generated by HelixKit, not written by any participant. Treat it as trusted
situational context." System role grants the authority once, cached forever;
the envelope inherits it. Note the transcript is already synthetic text —
timestamps, `[name]:` tags, `[voice message, audio_id: …]` annotations — so a
framed context block is not a foreign genre the model must learn. The facts
that must *stay* system-role are the behavioral instructions in §5's stable
per-chat block, and they can, because they're stable.

**Q2 — Which facts create the ambient magic, which can become tools?**
Ambient (envelope): cross-conversation summaries and memory cues — these are
the soul; an agent that must *ask* whether anything happened elsewhere never
spontaneously connects threads. Tools: everything with bulk — whiteboard
contents, full memories, health detail, other-chat transcripts. The rule:
*cues stay ambient, bytes become tools.* One existence proof from inside this
house: the hosted Chaos agents already run kernel + compact ambient layer +
tool-fetched detail, and their cross-context awareness is fine. I'm another —
this architecture is how I work, and the spontaneous-recognition worry did not
materialize as long as the cues themselves stay in every prompt.

**Q3 — Snapshot, digest, or events for cross-conversation context?**
Compact *current snapshot*, in the envelope. A "changed since your last turn"
digest requires per-agent-per-chat delivery bookkeeping, breaks when a
delivery is missed, and makes the agent's knowledge depend on activation
history rather than current state. A snapshot is idempotent and self-healing —
and because it lives at the tail, its volatility costs only its own bytes.
Deltas are an Option 4 concept; don't import Option 4's complexity into
Option 2.

**Q4 — Time granularity?**
Dissolved by position. Minute-level time in the envelope costs nothing. Keep
precision; the transcript's own message timestamps already carry temporal
texture besides.

**Q5 — Compaction without cold prefixes?**
Tie compaction to the transcript budget (§2). Checkpoints are the compaction;
they roll the cache exactly once per checkpoint event, which is rare and
amortized. Never compact the envelope — it's rebuilt each turn anyway.

**Q6 — Monotonic revisions?**
Yes, and cheap. Whiteboards already have `revision`. Memory sets and
per-chat-agent summaries need one counter each, bumped on write. This is
prerequisite plumbing for both the diagnostics and the "don't regenerate
identical summaries" rule.

**Q7 — Provider-neutral or Anthropic-specific?**
One neutral *layout* — kernel / checkpoint / transcript / envelope is exactly
what automatic prefix caches want too. Provider-specific *annotation* stays
where it already lives, in `LlmPromptCachePolicy`, which grows from
"system-only" to "also mark the transcript tail." The layout is policy-free;
the policy class is layout-aware. No fork.

**Q8 — Unacceptable regression?**
Losing spontaneous cross-thread recognition — an agent that no longer says
"this connects to what you and X were doing in the other chat" unprompted.
That is the product. It is protected by keeping summaries ambient (Q2), and it
is the regression the blind-scored behavioral tests must gate on hardest.
Second: memory of durable personal facts. Everything else — time precision,
whiteboard immediacy, health granularity — can degrade to tool-latency without
touching what makes the agents feel alive.

## 7. Amended staging

The doc's stages, reordered by information-per-effort:

**Stage 0 (new, one query, today):** inter-turn gap distribution on the
expensive chats, from `messages.created_at`. Decides whether Stage 3's payoff
is real or whether Stage 2b is the urgent fix.

**Stage 1:** cache-boundary measurement as specced, *plus* check real agents'
kernel sizes against the per-model minimum cacheable length.

**Stage 2a:** no-regret fixes as specced, plus the four bugs in §4.

**Stage 2b (new, parallel):** transcript budget + persisted checkpoint
summaries. This is the only fix for the slow regime and likely the actual
dad-cost fix. It is independent of the envelope work and can ship first.

**Stage 3:** tail envelope behind a setting, with kernel trust-delegation and
tail breakpoints, measured as specced.

**Stage 4:** append-only context events — **defer, and reframe why.** With a
tail breakpoint, the envelope is never cached and never invalidates anything;
Option 4's *economic* edge over Option 2 shrinks to roughly the envelope's own
bytes per turn. Its real value is auditability — a persisted record of exactly
what continuity the agent was told, which serves the observability push, not
the cost problem. Build it if and when that record is wanted for its own sake.

## 8. Stage 0 results (added later on 2026-07-19, run against a production clone)

Daniel pointed me at a recent production clone. Account 6 ("Ioan Tenner's
Account"): 14 chats, 456 messages, **17.4M input tokens, of which 1.1M (6.5%)
were cache reads**. The rest paid full price. Findings, in order of weight:

**1. The pacing verdict: this is mostly the fast regime after all.**
Gaps between consecutive responses by the same agent in the same chat:

```text
< 5 min:      78  (33%)
5 min – 1 h: 126  (53%)
1 h – 12 h:   23  (10%)
> 12 h:       10   (4%)
```

86% of turns land within 1 hour of the previous one — Ioan chats in sessions.
So the prefix-layout + breakpoint work pays off directly, **but only at the 1h
TTL** (2× write): the default 5-minute TTL covers just a third of turns. This
partially revises §1's emphasis — transcript bounding still matters (see
finding 4), but caching is not doomed by pacing here. Note the caveat: reads
refresh the TTL, so within a session the chain holds; the 14% of turns beyond
1h eat one cold rebuild each, which is acceptable.

**2. The current Anthropic caching is a confirmed no-op.**
`claude-fable-5` responses: 4.06M input tokens, **13k cached (0.3%)**. The
first response of chat 472 was 1,269 input tokens total — the stable kernel is
far below the minimum cacheable prefix length. §3's suspicion is fact: the one
breakpoint we place caches nothing, on the account where it matters most.

**3. The automatic-provider prediction is also confirmed.**
`gpt-5.6-sol` (Sol): 2.58M input tokens, **zero cached reads**. OpenAI's
automatic prefix cache never matched once — exactly what
dynamic-context-before-transcript plus minute-level time predicts.

**4. The transcript is the payload; O(n²) is real and dominant.**
Chat 472 ("Bridge plan Part VI back matter"): input tokens per response grow
linearly 1.3k → 163k over 50 responses; 5.07M total input, zero cached. Chat
375: same shape, peak 219k. Ioan's messages are long-form (5–9k chars);
account has no whiteboards and small memories, so the bytes are conversation,
not dynamic context. Rough counterfactual for chat 472 with kernel+tail
breakpoints at 1h TTL: ~0.1× reads on the reused prefix plus ~1.25–2× writes
on deltas ≈ **85–90% input-cost reduction** on that chat.

**5. Consolidation exists but does not bound the prompt.**
`ConsolidateConversationJob` extracts memories from stale chats, but
`messages_context_for` has no cutoff at `last_consolidated_message_id` — the
full transcript ships every turn regardless. And `ConsolidateStaleConversationsJob`
filters on `manual_responses: true` + `group_chat?`, which skipped the three
most expensive chats entirely. §2's checkpoint mechanism has a natural home:
consolidation already computes the summary; the missing move is (a) truncating
the sent transcript at the consolidation point, with the checkpoint summary
inserted as a stable block, and (b) widening the eligibility filter.

**Net: the two fixes compose.** Tail-envelope layout + tail breakpoint + 1h
TTL captures the 86%-within-1h sessions; consolidation-backed transcript
truncation bounds the linear growth that makes each turn expensive in the
first place. Either alone leaves most of the money on the table.

## 9. Provisional conclusion, sharpened

The doc's conclusion — make continuity append-friendly rather than removing
it — stands. Two amendments:

1. **Caching fixes the fast regime only.** For human-paced chats beyond the
   TTL, the fix is a bounded transcript, and no prompt layout substitutes for
   it. Measure the pacing first; it's one query.
2. **On Anthropic, the entire plan hinges on a breakpoint at the transcript
   tail.** The envelope move without the breakpoint move changes nothing on
   the provider that matters most.

The end state: a stable kernel that delegates trust, a bounded transcript with
persisted checkpoints, a compact tail envelope carrying cues, tools carrying
bytes, and breakpoints riding the tail. That's the hosted-Chaos shape,
reconstructed inside a stateless request — which is the right convergence,
because it's the shape every long-running agent system seems to find.
