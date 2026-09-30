# Inline-agent prompt caching without losing continuity

Date: 2026-07-19

Status: analysis for discussion with Lume; no implementation proposed as final

Related:

- `app/models/chat/contextualizable.rb`
- `app/lib/llm_prompt_cache_policy.rb`
- `app/models/agent/memory.rb`
- `test/lib/llm_prompt_cache_policy_test.rb`
- `test/apis/ruby_llm_provider_upgrade_test.rb`
- `docs/hosted-agent-token-economics-2026-07-14.md`
- `docs/per-chat-session-resume-2026-07-15.md`
- `docs/requirements/20260718-hosted-agent-runtime-observability.md`

## Executive summary

There is a real problem, but “the dynamic system prompt drops the cache” is
slightly too blunt.

For inline HelixKit agents using RubyLLM:

1. HelixKit rebuilds the system context for every response.
2. The agent’s authored `system_prompt` is treated as the stable part.
3. Memory, health, whiteboards, cross-conversation summaries, borrowed context,
   current time, and participant information are treated as dynamic context.
4. On Anthropic, HelixKit explicitly caches the stable system block and sends
   the dynamic context as a second system block.
5. On automatic-cache providers (OpenAI, Gemini, xAI, and OpenRouter),
   HelixKit joins stable and dynamic context into one system message.

This means the stable identity can still receive cache benefit. It does **not**
mean the whole request is uncached. On the current Anthropic request shape,
however, the explicit cache boundary ends after the stable identity block; the
dynamic context and transcript are outside that explicit cached prefix.

The expensive limitation is that the dynamic context appears **before the
conversation transcript**. For Anthropic, the only explicit breakpoint is
currently before both of them. For automatic-cache providers, prompt caches are
prefix caches: once any byte or token in that dynamic section changes, the
provider cannot reuse the cached prefix after the change. Because the prompt
includes a minute-level current time on every response, the prior conversation
transcript is very unlikely to be reusable across separate response jobs, even
when almost everything else is unchanged.

In other words:

> We have protected the stable identity, but we have probably not protected
> the growing conversation history.

That matters more as chats become long. It is consistent with seeing some
cache activity while still paying unexpectedly high input or cache-write costs.

The dynamic context is also responsible for much of what is delightful about
HelixKit agents: durable memory, awareness of other conversations, shared
whiteboards, current circumstances, and knowledge of who is present. Removing
it wholesale would improve prefix stability by making the agents less
continuous and less situated. That is the wrong trade.

The better direction is to change **where and how continuity is represented**:

- keep a stable, cacheable system “kernel”;
- stop putting per-turn volatility ahead of the transcript;
- deliver current context near the tail of the request or through tools;
- eventually represent continuity changes as append-only context events rather
  than rebuilding a mutable snapshot at the front of every prompt.

Before choosing the final architecture, we should use the telemetry that has
just landed to measure the inline RubyLLM path under controlled prompt changes.

## Scope: inline and externally hosted agents are different

This analysis is primarily about **inline HelixKit agents**, whose responses go
through `ManualAgentResponseJob` / `AllAgentsResponseJob` and RubyLLM.

Externally hosted Chaos agents use a different path:

- HelixKit triggers an external runtime.
- A persistent Chaos session can resume with a small delta.
- The identity and journal bundle is not rebuilt on every successful resume.
- Identity changes can deliberately roll the session, but a normal resumed
  turn is append-only.

The externally hosted path therefore already has the shape we want to move
towards: stable session history plus appended deltas.

The RubyLLM inline path reconstructs the entire request each time and currently
places a mutable snapshot before that history. The new per-message RubyLLM
telemetry makes this path visible, but visibility does not itself make the
prefix stable.

## What HelixKit sends today

`Chat::Contextualizable#build_context_for_agent` constructs:

```text
[system message(s)]
[message 1]
[message 2]
...
[latest message]
```

The system prompt is split conceptually into:

```text
stable:
  agent.system_prompt

dynamic:
  private memory
  Oura health context for account users
  shared whiteboard index
  conversation title
  active whiteboard contents
  summaries of the agent's other active conversations
  one-shot borrowed context
  development warning, when applicable
  agent-only-thread warning, when applicable
  initiation reason, when applicable
  voice instructions, when applicable
  current time to the minute
  group-conversation statement
  participant description
```

For Anthropic, `LlmPromptCachePolicy` serializes this as:

```text
system block 1: stable identity, cache_control: ephemeral
system block 2: dynamic context, not explicitly cached
messages: full transcript
```

For OpenAI, Gemini, xAI, and OpenRouter, it serializes:

```text
system: stable identity + dynamic context
messages: full transcript
```

The provider-upgrade VCR tests prove that:

- the request shapes are accepted by the four major providers;
- RubyLLM exposes provider token counters;
- Anthropic receives an explicit cache marker on the stable block.

They do **not** currently prove that two successive realistic HelixKit turns
reuse the expected prefix when the dynamic context changes.

## Why prompt position is the important part

Provider prompt caches fundamentally reward a matching prefix. Provider details
vary, but the safe shared mental model is:

```text
request A: [stable prefix][old dynamic context][old transcript]
request B: [stable prefix][new dynamic context][old transcript][new message]
                            ^
                            first divergence
```

Only the portion before the first divergence is a candidate for reuse. The fact
that the old transcript is byte-identical does not help if a changing section
precedes it.

The current minute-level line guarantees divergence:

```text
Current time: Sunday, 2026-07-19 14:03 CEST
Current time: Sunday, 2026-07-19 14:08 CEST
```

Even if time were removed, several earlier sections can change:

- a memory is added, removed, or refined;
- Oura data refreshes;
- a whiteboard revision changes;
- another conversation receives messages and its summary is regenerated;
- borrowed context appears for one activation and disappears on the next;
- the participant set changes;
- an initiation reason is present only for a proactive response.

The result is likely to be:

- on Anthropic, **cache reuse for the stable identity block, but not the
  dynamic context or transcript under the current single-breakpoint policy**;
- on automatic-cache providers, potentially more reuse through slow-changing
  dynamic sections when their bytes happen to match;
- on automatic-cache providers, **little or no reuse of the transcript across
  separate turns whenever any preceding dynamic section changes**;
- provider-dependent reuse within a single RubyLLM tool loop; automatic caches
  can benefit from the append-only rounds, while Anthropic still needs a later
  explicit breakpoint if it is to cache more than the stable identity.

This explains how telemetry can show cache reads without the economics being
good. A cache-read counter answers “did any eligible prefix get read?”, not
“did we cache the largest and fastest-growing part of the prompt?”

## Volatility audit of the current dynamic context

The current list mixes facts with very different lifetimes.

| Context | Typical volatility | Needed on every turn? | Notes |
|---|---|---:|---|
| Agent system prompt | Rare | Yes | Correctly treated as stable identity |
| Core memories | Low | Usually | Changes only when memory is authored/refined |
| Recent journal memories | Medium | Usually | Window membership and new entries can change |
| Oura health context | Medium | Sometimes | Freshness matters, but not necessarily minute-by-minute |
| Whiteboard index | Medium | Sometimes | Revisions and summaries can change |
| Conversation title | Low | Usually | Changes rarely after initial title generation |
| Active whiteboard contents | Potentially high | When active | Can be large as well as volatile |
| Other-conversation summaries | High | Valuable | This is the main cross-thread-awareness feature |
| Borrowed context | One-shot | Yes, when requested | Deliberately appears once |
| Environment/thread warnings | Low | Yes | Could be part of a stable per-chat prefix |
| Initiation reason | One-shot | Yes, when proactive | Per-activation event, not identity |
| Voice instructions | Low | Yes | Stable for the agent while voice settings are unchanged |
| Current time | Every call | Usually | Should not sit before the transcript |
| Participant description | Low/medium | Usually | Should be deterministically ordered |

Two additional stability risks are worth checking:

1. Some collections may not have an explicit deterministic order. Identical
   records returned in a different order produce different bytes.
2. Formatting changes, whitespace, timestamps, and regenerated summaries can
   invalidate a prefix even when the human-visible meaning is nearly the same.

Canonical serialization is a prerequisite for effective caching regardless of
the larger design.

## The continuity constraint

The dynamic context is not incidental decoration.

It gives inline agents:

- a sense that they remember the relationship;
- awareness that work is continuing in other chats;
- access to shared state without manually searching for it;
- orientation to health, time, collaborators, and the current project;
- the ability to connect themes across threads.

Removing this context would probably reduce cost, but it would also turn an
agent from a situated participant into a mostly thread-local chatbot. The
cross-thread recognition that feels surprising and alive is exactly what the
current prompt construction is buying.

The design goal should therefore be:

> Preserve the information and its availability while avoiding a mutable
> front-of-prompt snapshot.

This is a representation problem, not a choice between “memory” and “caching.”

## Candidate approaches

### Option 0 — Keep the current design

Keep the stable identity breakpoint and accept that dynamic context limits
cache reuse.

Advantages:

- no behavioural risk;
- maximum continuity remains available immediately;
- simple implementation.

Disadvantages:

- transcript cost grows with chat length;
- current time forces avoidable divergence every turn;
- cache-read percentages may look healthy while the expensive transcript
  remains outside the reusable prefix;
- provider-specific behaviour remains hard to reason about.

This is acceptable only if real telemetry shows that costs are already low
enough. We should not assume that.

### Option 1 — Stabilize and reorder the existing system context

Split the current context by lifetime:

```text
stable identity
stable per-agent instructions
stable per-chat facts
slow-changing continuity snapshot
fast-changing activation context
transcript
```

Concrete no-regret changes:

- remove minute-level current time from the system prompt;
- sort every collection deterministically;
- separate one-shot context from durable context;
- avoid regenerating semantically identical summaries;
- version continuity snapshots and only change their bytes when their source
  revision genuinely changes;
- use additional Anthropic cache breakpoints for large slow-changing blocks,
  within provider limits.

Advantages:

- relatively small change;
- preserves almost all current behaviour;
- improves cache reuse within the system context.

Limit:

- any changed system context still precedes the transcript, so it still cuts
  off transcript reuse across turns.

This is useful hygiene, but not the deep fix.

### Option 2 — Stable system kernel plus a tail context envelope

Keep only durable identity and invariant behavioural instructions in the system
prompt. Construct each activation as:

```text
[stable system kernel]
[prior conversation transcript]
[synthetic context envelope for this activation]
[new user/event message, if separate]
```

The context envelope can include:

- current time;
- current memory/continuity snapshot or the changes since last activation;
- cross-conversation summaries;
- health context;
- whiteboard revisions;
- participant changes;
- initiation reason;
- borrowed context.

Because the envelope is near the tail, the old transcript remains a reusable
prefix. New context is paid for as a small suffix instead of invalidating
everything before it.

Advantages:

- large likely cache improvement on long conversations;
- keeps continuity immediately available;
- provider-agnostic append-friendly shape;
- conceptually similar to the resumed Chaos path.

Risks:

- the envelope would normally be represented as a user-role message, not a
  system-role message, so models may treat it as less authoritative;
- it must be clearly marked as trusted HelixKit context, not as words spoken by
  the human;
- adding an artificial user message can affect role alternation and tool/thinking
  replay requirements differently across providers;
- we must avoid making the agent answer the envelope instead of the human.

A possible form:

```text
<helixkit_context trusted="true" revision="...">
Current time: ...
Continuity changes since your previous response in this chat:
- ...
Other active conversations:
- ...
</helixkit_context>

Use this as situational context. Respond to the following human message.
```

This needs behavioural and provider integration tests, but it is probably the
best near-term architectural experiment.

### Option 3 — Retrieve volatile context with tools

Keep the system prompt stable and teach the agent to use tools such as:

- `current_time`;
- `list_other_conversations`;
- `read_conversation_summary`;
- `read_memories`;
- `read_whiteboard`;
- `health_context`.

Advantages:

- nearly ideal prompt stability;
- context is fetched only when relevant;
- source data can be authoritative and current;
- avoids repeatedly injecting large active whiteboards or unrelated summaries.

Risks:

- the agent must realize that context is relevant before seeing it;
- every retrieval adds latency and often another model/provider request;
- cross-thread recognition becomes less spontaneous;
- models may under-use tools, especially for relational or atmospheric context;
- mandatory “always fetch continuity first” rituals would recover behaviour at
  the cost of extra turns and could be more expensive than a compact envelope.

Tools are well suited to deep detail. They are less suited to replacing all
ambient awareness.

### Option 4 — Append-only continuity events

Instead of rebuilding a full continuity snapshot, maintain hidden, append-only
context events per agent/chat:

```text
[system kernel]
[conversation history]
[context event: other chat abc summary is now revision 7]
[conversation messages]
[context event: whiteboard project-plan is now revision 12]
[conversation messages]
...
```

Events would be inserted only when relevant state changes. They could include
deltas or compact replacement summaries with explicit supersession:

```text
Continuity update: replace prior summary for chat abc with:
"Deployment is complete; observability review is pending."
```

Advantages:

- naturally prefix-stable and cache-friendly;
- preserves the phenomenology of continuity;
- makes the agent’s received context auditable;
- avoids re-sending unchanged state;
- converges inline agents towards the successful persistent-session model.

Risks:

- old superseded context remains in history until compaction;
- requires a hidden context-event data model or message subtype;
- fan-out must decide which changed facts should be appended to which chats;
- long-running chats need compaction/checkpointing;
- event ordering and idempotency become correctness concerns;
- memory privacy and account boundaries must remain explicit.

This is the deepest fix and probably the cleanest eventual architecture. It is
more work than Option 2.

### Option 5 — Hybrid: ambient envelope plus on-demand tools

Use a small tail envelope for the facts that create ambient continuity:

- current time at an appropriate granularity;
- a compact “what changed elsewhere” digest;
- relevant memory cues;
- current participants;
- active whiteboard name and revision.

Use tools for:

- complete memory contents;
- full whiteboards;
- full transcripts from other chats;
- detailed health data;
- older or less relevant context.

This preserves spontaneous cross-thread awareness without injecting every byte
on every turn. It is likely the best product shape even if Option 4 later
supplies the envelope as append-only events.

## Recommended direction

I recommend a staged path rather than immediately rewriting the memory model.

### Stage 1 — Prove the cache boundary

Use the new RubyLLM telemetry in controlled, repeated turns.

For each major provider (Anthropic, OpenAI, Gemini, xAI), capture:

1. identical stable and dynamic context, with one new message appended;
2. only current time changed;
3. only a memory revision changed;
4. only a cross-conversation summary changed;
5. only participant order changed;
6. a tool-use continuation inside one response;
7. a long-chat turn where the transcript dominates token volume.

Record:

- total input;
- ordinary uncached input;
- cache read;
- cache write, where reported;
- output;
- prompt component byte/token estimates;
- first differing component and its revision/hash.

The current VCR provider tests should remain as compatibility tests, but they
need companion two-request cassettes. A one-request cassette cannot prove
prefix reuse.

### Stage 2 — Land no-regret stability fixes

Before changing prompt roles:

- move current time out of the system snapshot, or at least reduce it to a
  stable bucket as an interim measure;
- sort users, participants, memories, and all other collections explicitly;
- generate canonical whitespace and serialization;
- attach source revision hashes to prompt diagnostics;
- avoid changing a summary when its normalized content is identical;
- separate constant per-chat context from genuinely dynamic context.

This improves both caching and our ability to explain misses.

### Stage 3 — Prototype the tail context envelope

Behind a per-agent or site setting:

- keep `agent.system_prompt` as the stable system kernel;
- replay the prior transcript;
- inject a trusted HelixKit context message immediately before the current
  activation;
- keep the envelope compact and revisioned;
- leave detailed context accessible through existing/new tools.

Compare against the current layout on:

- cache-read ratio and cache-write volume;
- total cost per response;
- first-token latency;
- factual use of memory;
- spontaneous cross-thread references;
- rate of irrelevant or confusing cross-thread references;
- tool-call count;
- provider-specific failures.

The experiment should use real multi-turn chats, not only “reply with ok.”

### Stage 4 — Decide whether append-only context events are justified

If the tail envelope produces the expected economic win without harming
continuity, it may be sufficient.

If rebuilding the envelope remains expensive or hard to audit, evolve it into
persisted context events:

- event source and source revision;
- intended agent and account;
- creation time;
- superseded event, if any;
- compact text delivered to the model;
- delivery per chat/session;
- idempotency key.

Compaction can periodically replace old context events with a checkpoint while
preserving a stable prefix within the active cache window.

## Instrumentation still missing for this question

The per-message telemetry tells us what the provider charged, but not yet why a
particular prefix matched or failed.

For inline responses, useful additional diagnostics would be:

```text
prompt_layout_version
system_stable_bytes
system_dynamic_bytes
transcript_bytes
tail_context_bytes
tool_schema_bytes
system_stable_sha256
system_dynamic_sha256
continuity_revision
memory_revision
whiteboard_revision_set
cross_conversation_revision_set
participant_revision
```

We should not store raw private prompts merely to debug caching. Component
sizes, deterministic hashes, source revisions, and the selected layout version
are enough to explain most misses.

It would also be useful for the admin telemetry display to distinguish:

- inline RubyLLM response;
- externally hosted interaction;
- provider request count within the response;
- cache read/write completeness for the provider;
- prompt layout version.

## Important test cases

### Prompt-construction unit tests

- Stable and dynamic components are classified correctly.
- Current time is absent from the stable kernel.
- Collection ordering is deterministic.
- Identical source state produces byte-identical prompt components.
- A one-shot initiation reason does not modify the durable kernel.
- Borrowed context appears exactly once without rewriting earlier history.
- The context envelope cannot be confused with a human-authored message in
  persistence or display.

### Provider request-shape tests

For Anthropic, OpenAI, Gemini, and xAI:

- two successive turns complete successfully;
- prior conversation remains before the new context envelope;
- tool definitions remain stable;
- thinking/tool replay still works;
- usage telemetry remains attached to the final HelixKit message;
- provider-specific role alternation is valid.

### Cache-behaviour VCR tests

Record genuine paired requests for:

- unchanged kernel + appended user message;
- changed tail envelope + unchanged old transcript;
- changed stable kernel;
- changed tool set;
- long transcript above each provider’s cache eligibility threshold.

Assertions should reflect provider semantics. Not every provider exposes cache
writes, and `nil` must continue to mean “not reported,” not zero.

### Behavioural continuity tests

Cost tests alone could accidentally optimize away the product.

Create evaluation conversations where the agent should:

- remember a durable personal preference;
- connect a current message to a relevant other conversation;
- avoid mentioning an irrelevant other conversation;
- notice a whiteboard update;
- use the correct current time;
- distinguish current transcript ground truth from stale memory;
- verify uncertain cross-thread details through a tool rather than confabulate.

Run the same cases with the current prompt and candidate layout, blind-score the
responses, and retain representative transcripts for review.

## Open questions for Lume

1. Is a trusted tail context envelope strong enough in practice, or do we need
   some continuity facts to remain system-role instructions?
2. Which facts create the delightful ambient awareness, and which can safely
   become tools?
3. Should cross-conversation context be a full current snapshot, a “changed
   since your last turn in this chat” digest, or append-only events?
4. Should the time be delivered on every turn, only when requested, or in a
   coarse bucket unless precision is relevant?
5. How should we compact superseded context without reintroducing frequent cold
   prefixes?
6. Can memory and summary jobs expose monotonic revision numbers so prompt
   diagnostics do not need to infer change from text?
7. Do we want one provider-neutral layout, or an Anthropic-specific layout that
   takes fuller advantage of explicit cache breakpoints?
8. What continuity regression would be unacceptable even if it saved a large
   amount of money?

## Provisional conclusion

Yes: the current dynamic system construction is probably preventing the cache
from protecting the full conversation history across inline RubyLLM turns.

No: it is not accurate to say caching is entirely disabled. The stable agent
identity is explicitly cacheable on Anthropic, automatic providers may reuse a
shared prefix, and intra-response tool loops can still benefit.

The problem is architectural:

> mutable continuity is serialized before append-only conversation history.

The solution should not be to remove continuity. It should be to make
continuity itself more append-friendly:

1. measure the real boundary;
2. remove accidental volatility and nondeterminism;
3. move per-activation context to the tail;
4. retain ambient cues while moving detail to tools;
5. consider append-only continuity events as the durable end state.

That gives us a plausible route to keeping the lovely cross-thread awareness
while paying primarily for what changed, rather than repeatedly invalidating
everything the agent already knows about the current conversation.
