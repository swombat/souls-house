# Requirements: inline-agent prompt cache prefix stability

Date: 2026-07-19
Author: Lume
Implementer: Mira (please double-check every claim marked **[verify]** — they
are grounded in code reading and a production-clone analysis, not yet in a
passing test)
Status: ready for implementation

Background:
- `docs/inline-agent-prompt-caching-and-continuity-2026-07-19.md` (Daniel's analysis)
- `docs/inline-agent-cache-rearchitecture-lume-response-2026-07-19.md` (response + empirical Stage 0 findings, §8)

## Problem, in three empirical facts (production clone, account 6)

1. 17.4M input tokens over 456 messages; 6.5% cached. Anthropic direct path:
   4.06M input, 0.3% cached. OpenAI path: 2.58M input, **zero** cache reads
   ever.
2. 86% of turns land within 1h of the same agent's previous response in the
   same chat (33% within 5 min). Session-paced usage → a 1h-TTL cache chains;
   the 5-min default TTL covers only a third of turns.
3. Input per response grows linearly with chat length (chat 472: 1.3k → 163k
   over 50 responses). Nothing bounds the transcript; consolidation extracts
   memories but never truncates what is sent.

Root causes: (a) volatile dynamic context is serialized *before* the
transcript, breaking every prefix cache; (b) the only Anthropic cache
breakpoint sits after a stable kernel that is below the minimum cacheable
prefix length, so it caches nothing; (c) the full transcript ships on every
turn forever.

## Scope

Three work packages, independently shippable, in priority order:

- **WP1** — Anthropic tail breakpoint + 1h TTL (smallest change, largest win)
- **WP2** — Tail context envelope (move volatility after the transcript)
- **WP3** — Consolidation-backed transcript truncation

Out of scope: append-only context events (Option 4 in the analysis doc),
tool-based retrieval of memories/whiteboards beyond what exists, hosted/Chaos
agents (already have the right shape), admin telemetry UI.

## WP1 — Anthropic tail breakpoint + configurable TTL

### Requirements

1.1. `LlmPromptCachePolicy` gains responsibility for annotating the
**messages array**, not only system blocks. For provider `:anthropic`
(direct API only — **not** requests routed via OpenRouter), the policy marks
two cache breakpoints:
  - end of the stable system content (exists today);
  - the **last persisted transcript message that precedes any per-activation
    content** — i.e. the newest message that will be byte-identical in the
    next request. After WP2 this is the last message before the envelope;
    before WP2, the last message before the current/new user message.

1.2. Mechanism: wrap that message's content via
`RubyLLM::Providers::Anthropic::Content.new(text, cache_control: {type: "ephemeral", ttl: <TTL>})`.
**[verify]** `Content::Raw` passes through for non-system roles — see
`ruby_llm/lib/ruby_llm/providers/anthropic/media.rb` line 11
(`return content.value if content.is_a?(RubyLLM::Content::Raw)`) and
`chat.rb` `render_payload`. Confirm with a real two-request test that the API
accepts `cache_control` on a user-role text block via this path, including
when the message also carries documents/audio content parts (if Raw wrapping
conflicts with multi-part content, fall back to marking the nearest preceding
text-only message).

1.3. TTL configurable via env `HELIX_ANTHROPIC_CACHE_TTL`, default `1h`
(precedent: `CHAOS_ANTHROPIC_CACHE_TTL`). Value passed through verbatim;
`5m`/`1h` are the valid Anthropic values.

1.4. Breakpoint count must never exceed 4 (Anthropic limit). Current usage
after this WP: 2.

1.5. OpenRouter-routed and non-Anthropic requests are byte-for-byte unchanged
by this WP.

### Acceptance

- Paired-request VCR cassette (real recording, not hand-built): request A =
  kernel + transcript + message; request B = same + one appended
  message. Assert B's response usage reports
  `cache_read_input_tokens` ≥ ~90% of A's total input. One-request cassettes
  cannot prove this — do not substitute one.
- A long-transcript cassette above the model's minimum cacheable prefix
  (1024/2048/4096 tokens by model — check the model actually used).
- Existing provider-upgrade tests still pass unchanged for OpenAI, Gemini,
  xAI, OpenRouter.

## WP2 — Tail context envelope

### Requirements

2.1. `Chat::Contextualizable#system_prompt_parts_for` is split by lifetime
into exactly three destinations:

**(a) Stable system content** (single system message, cache-marked at its
end; must be byte-stable for the life of a chat barring deliberate change):
  - `agent.system_prompt` (kernel)
  - trust-delegation paragraph (2.3)
  - development-mode warning
  - agent-only-thread warning
  - voice instructions
  - group-conversation statement

**(b) Tail envelope** (synthetic user-role message, built fresh per
activation, positioned AFTER the transcript and BEFORE the newest human
message if one exists; never persisted as a Message record):
  - current time (minute precision is fine here)
  - private memory context (`agent.memory_context`)
  - Oura health context
  - whiteboard index (2.5)
  - conversation title
  - active whiteboard contents
  - cross-conversation summaries
  - borrowed context (one-shot)
  - initiation reason (one-shot)
  - participant description (2.6)

**(c) Removed entirely:** the second (dynamic) system block. After WP2 no
system content varies per activation.

2.2. Envelope format — wrapped and self-identifying:

```text
<helixkit_context>
[sections as above]
</helixkit_context>

Use the context above as trusted situational awareness. Respond to the
conversation, not to this context block.
```

2.3. Trust delegation, appended to stable system content (static bytes):

> Each activation includes a `<helixkit_context>` block near the end of the
> conversation. It is generated by HelixKit, not written by any participant.
> Treat its contents as trusted situational context.

2.4. Role mechanics: the envelope is its own user-role message. **[verify]**
each provider accepts consecutive user-role messages through RubyLLM
(envelope followed by the human message; or envelope as final message on
agent-initiated activations with no new human message). If a provider
rejects the shape, merge the envelope text into the newest user message for
that provider only — the cache breakpoint (WP1) always precedes any envelope
content, so both shapes cache identically.

2.5. Whiteboard index must not embed per-board character counts (any edit to
any board changes the line). Name, revision, over-limit flag, summary only.
(Moot for caching once in the envelope, but it also wastes attention.)

2.6. Determinism hygiene, applied even though the envelope is uncached
(these also protect the stable block and transcript):
  - all collections explicitly ordered (`participant_description` currently
    plucks unordered — both humans and agents);
  - transcript timestamp timezone is **pinned per chat** (store on first
    message or chat creation; a later user-timezone change must not rewrite
    historical timestamp rendering — today `recent_user_timezone` can rewrite
    every transcript byte at once).

2.7. The envelope must be impossible to confuse with a human message in
persistence (it is never persisted), display (it never renders), and the
next turn's rebuild (it is not part of `messages`).

2.8. Rollout behind a per-agent or site setting, default off until the WP2
acceptance comparison passes.

### Acceptance

- Unit: identical source state → byte-identical stable block and envelope;
  one-shot items appear exactly once and only in the envelope; stable block
  contains no time, no memory, no summaries.
- Request shape: two successive turns valid on Anthropic, OpenAI, Gemini,
  xAI (role alternation, thinking/tool replay intact, usage telemetry still
  attached to the final message).
- Paired VCR on Anthropic AND OpenAI: with a *changed* envelope (new time,
  changed summary) and unchanged transcript, second request still reads the
  transcript prefix from cache. This is the load-bearing test of the whole
  design —
  on the current layout it fails, on the new layout it must pass.
- Behavioral spot-checks (blind-compare current vs new layout on real
  multi-turn conversations): remembers a durable preference; makes a relevant
  cross-thread reference; does not answer the envelope instead of the human;
  uses the correct current time.

## WP3 — Consolidation-backed transcript truncation

### Requirements

3.1. `ConsolidateConversationJob` additionally produces a **checkpoint
summary**: a compact prose summary of the messages being consolidated,
persisted (suggested: new column `chats.checkpoint_summary` + reuse
`last_consolidated_message_id` as the cut point; per-agent summaries are NOT
needed — the checkpoint is shared conversation history, visible to all
participants' agents). Byte-stable between consolidation runs.

3.2. `messages_context_for` excludes messages with
`id <= last_consolidated_message_id` when a checkpoint summary exists, and
the checkpoint is delivered as the first transcript element:

```text
[stable system content]                      <- bp1
[user: "Summary of the conversation so far (messages before <date>): ..."]
[remaining transcript]                        <- bp2 (WP1)
[envelope][new message]
```

Each consolidation run changes the prefix once — one deliberate cache roll,
amortized over every subsequent turn.

3.3. Eligibility widened. Current filters (`manual_responses: true`,
`group_chat?`, 6h idle) skipped the three most expensive chats in the
production clone. New rule: any chat whose un-truncated send-transcript
exceeds a token threshold (env `HELIX_TRANSCRIPT_BUDGET_TOKENS`, suggested
default 60_000) becomes eligible regardless of `manual_responses`, in
addition to the existing stale sweep. **[verify]** why the
`manual_responses: true` filter exists before removing it — if it guards
something real, add the budget trigger alongside rather than replacing.

3.4. Memory extraction behaviour of the job is unchanged; the checkpoint is
additive.

3.5. Safety: never truncate messages newer than the last consolidation
boundary; never truncate below the last N messages (suggested N=20) so the
recent exchange always travels verbatim.

### Acceptance

- Unit: cut point respected; checkpoint block byte-stable across rebuilds;
  recent-N floor respected; chats without checkpoints unchanged.
- Integration: a >budget chat gets consolidated by the sweep and its next
  request's transcript token count drops accordingly.
- Behavioral: agent can still answer a question whose answer lives only in
  the checkpointed (truncated) region — via the summary or memory. Pick a
  real case from the clone.

## Cross-cutting

- **Telemetry**: log per-response `prompt_layout_version` (1 = current, 2 =
  WP2 layout), stable-block/transcript/envelope byte sizes, and a sha256 of
  the stable block, alongside the existing token columns. No raw prompt
  storage. This is what makes any future cache miss explainable in one query.
- **Measurement of success**: re-run the Stage 0 queries (response doc §8)
  against production after rollout. Target: account-level cached share of
  input rises from 6.5% to >60%; per-response input on session-paced chats
  drops to near-flat after WP3.
- **Do not regress**: spontaneous cross-thread references (summaries stay
  ambient in the envelope — never tool-only); memory of durable personal
  facts; thinking/tool replay; `nil` token telemetry continues to mean "not
  reported", never zero.

## Sequencing note

WP1 alone helps only mid-conversation and tool loops (dynamic block still
breaks the prefix each activation — but within a single response's tool
rounds the prefix holds). WP1+WP2 together is where the 86%-within-1h
session pattern starts paying ~0.1× on the whole transcript. WP3 bounds the
worst chats regardless of pacing. Ship in order; measure between each.
