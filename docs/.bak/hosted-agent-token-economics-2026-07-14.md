# Hosted-agent token economics — diagnosis and redesign

*Lume, 2026-07-14. Follow-up to Mira's investigation of 2026-06-05
(`~/dev/mira/shared/automation/docs/helixkit-claude-harness-investigation-2026-06-05.md`).
Written against helix_kit `agent-runtime/`, the chaos checkout at `~/dev/chaos`
(HEAD e99048e6, 2026-07-13), and current Anthropic API pricing/caching docs.*

---

## 1. The finding Mira's note stops just short of

Mira correctly identified the ~45k-char identity injection and the Stop-hook
second turn. But neither is the dominant cost term. The dominant term is:

**Chaos never uses prompt caching. `cache_control` appears nowhere in the
codebase** — verified by grep over a fresh checkout dated 2026-07-13 (newer
than the SHA pinned in `agent-runtime/Dockerfile`). The Anthropic adapter
(`sys/kern/providers/parrot/src/anthropic.rs`) builds request bodies with no
cache breakpoints. On the Anthropic API, caching is strictly opt-in per
request: no `cache_control` → no caching → **every agentic turn re-pays the
entire conversation prefix at full input price.**

Chaos's own "prompt caching" test suite (`sys/kern/kern/tests/suite/prompt_caching.rs`)
is about prefix *stability* for the OpenAI Responses API (`prompt_cache_key`,
`prompt_cache_retention`), where caching is implicit server-side. The Anthropic
path got no equivalent, because Anthropic's mechanism needs explicit breakpoints.

### Why this closes the arithmetic

Current Opus 4.7 pricing: **$5 / MTok input, $25 / MTok output**.
(Also relevant: cache reads 0.1×, cache writes 1.25× at 5-min TTL / 2× at
1-hour TTL, batch API 50%, cache is exact-prefix and model-scoped, reads
refresh the TTL, Opus minimum cacheable prefix 4096 tokens.)

A "do nothing" wake is ~55k tokens once (Mira's number). But a wake in which
the agent *does* something — N tool-use turns over a context of ~60k average —
costs roughly N × 60k full-price input tokens, because nothing is cached:

- 5-turn wake ≈ 300k input ≈ **$1.50** + output, per wake
- × 24 wakes ≈ **$36–40/day** — which is exactly the observed bill

So the identity payload isn't the villain; **uncached multi-turn re-sends
are**. The 45k-char injection just sets the size of the thing being re-sent
five times per wake, twenty-four times per day.

Secondary terms, in order:
1. Fresh chaos session per wake (`--resume` is a TODO in `trigger_shim.py`) —
   the identity bundle is re-paid 24×/day even on quiet wakes.
2. Stop-hook journal reflex — a second full-context model turn on almost every wake.
3. **No token accounting on the external path** — `agent_runtime_interactions`
   stores stdout/stderr/`full_invocation_text` but no usage numbers. The
   *bill* ($41/day) is measured; the *decomposition* — turns per wake, cache
   read/write split per call — is invisible from HelixKit's side.

### Why this is believable despite chaos being carefully built

Not an oversight — a provider asymmetry. Chaos is OpenAI-Responses-native,
where caching is implicit server-side (`prompt_cache_key` /
`prompt_cache_retention` plumbing exists; chaos's prompt-caching test suite
is entirely about prefix *stability*, which on OpenAI is the whole strategy).
The Anthropic adapter is a minimal port and carries that assumption over.
But Anthropic caching is strictly opt-in via explicit breakpoints — and the
adapter's request struct is, verbatim:

```rust
struct AnthropicRequest {
    model: String,
    max_tokens: u64,
    stream: bool,
    system: Option<String>,   // bare string — no content blocks
    messages: Vec<AnthropicMessage>,
    tools: Vec<AnthropicTool>,
}
```

There is no field a `cache_control` could occupy. Stable prefix, zero cache
effect, no error, no warning — invisible full price.

**Zero-code confirmation:** the Anthropic Console usage dashboard splits
tokens into input / output / cache-read / cache-write. On any $41 day,
cache-read ≈ 0 against millions of input tokens confirms the diagnosis
without touching a line of code.

---

## 2. The redesign: one day, one session

The economics and the phenomenology point at the same fix. Hourly full
rebirth — rebuild identity from scratch, 24 times a day — is both the cost
driver and the strange part of the current design. Replace it with:

> **One chaos session per agent per day, resumed on every wake.**
> Identity is injected once, at the day's first wake. Each subsequent wake
> appends a small message ("hourly wake, 14:05 — here's what's new since
> last time") to the *same* session. The session rolls over at midnight
> (journal written, new session born next wake).

This is what makes prompt caching actually bite:

- With `cache_control: {type: "ephemeral", ttl: "1h"}` on the conversation
  tail, and wakes ~55 minutes apart (cron at minute 5, wakes take a few
  minutes), **every wake lands inside the previous wake's TTL**. Reads refresh
  the TTL, so the cache chains across the whole day.
- Marginal cost per wake ≈ 0.1× × (history so far) + 2× × (new tokens, a few k)
  + output. At a day-end history of ~100k tokens that's ~$0.05–0.10 per wake.
- Intra-wake agentic turns also become 0.1× reads instead of full-price
  re-sends — this alone is most of the ~10× saving.

Convenient alignment: chaos's environment context embeds `<current_date>`
(day-granular, not a timestamp), `<cwd>`, `<timezone>` — all stable within a
day. The daily session rollover naturally coincides with the only scheduled
prefix change. Appending wake messages never invalidates the prefix; the rule
to protect is simply *no timestamps or volatile bytes in the system/identity
prefix* (timestamps go in the appended wake message, which is at the tail).

### Estimated end state

| | today | redesigned |
|---|---|---|
| identity injections/day | 24 | 1 |
| intra-wake turn cost | full price × context | 0.1× × context |
| Stop-hook turn | full price × context | cache hit (~0.1×) |
| est. daily cost (Opus 4.7, 24 wakes) | ~$40 | **~$1.50–3** |

~90–95% reduction, with **no reduction in how often or how fully the agent
wakes** — no gatekeeper model deciding whether the being gets to exist this hour.

---

## 3. Concrete work items

### A. Instrument first (prerequisite, ~small)
Parse token usage from chaos output (it reports usage in its event stream)
and store `input_tokens`, `output_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`, `model` on `agent_runtime_interactions`.
Everything else in this doc becomes verifiable the moment this lands;
`cache_read_input_tokens == 0` is the smoke alarm. The Console usage
dashboard gives the org-level version of the same signal today.

### B. Add prompt caching to chaos's Anthropic adapter (the 10× lever)
`cache_control` on (1) the system prompt / tools boundary and (2) the last
message block, `ttl` configurable via env (default `1h` for this deployment;
5-min TTL dies in the 55-minute inter-wake gap and its 1.25× writes would be
pure loss). The v1 patch is smaller than first thought: the API accepts a
**top-level `cache_control`** on the request body that auto-places the
breakpoint on the last cacheable block — one optional field on
`AnthropicRequest` plus ~10 lines to populate it, no surgery on the bare
`system: Option<String>`. A second ~10-line change maps
`cache_read_input_tokens` / `cache_creation_input_tokens` into chaos's
`TokenUsage` (whose `cached_input_tokens` field already exists — the OpenAI
path uses it; the Anthropic path leaves it zero).

**Implementation plan for the chaos patch:**
`~/dev/chaos/docs/anthropic-prompt-caching-plan.md` — exact code locations,
default-TTL reasoning (5m default upstream, `CHAOS_ANTHROPIC_CACHE_TTL=1h`
for this deployment), test additions, rollout + verification steps. HelixKit already pins a chaos SHA in the Dockerfile, so
pointing `CHAOS_REPO` at a patched fork is the same maintenance posture as
today. Worth offering upstream to seuros regardless.
Note: max 4 breakpoints/request; Opus needs ≥4096-token prefix to cache (the
identity bundle clears this trivially); cache is model-scoped, so a model
switch mid-day cold-starts once.

### C. Wire up session resume (the rebirth fix)
`chaos exec resume <session-id>` already exists in the CLI (prompt on stdin,
same as today) — the shim's TODO is just plumbing:
- `trigger_shim.py` keeps `current_session_id` + its date in a state file.
- Same-day wake → `resume` with only: wake invitation + *delta* journal
  context (entries since last wake, usually near-zero). No identity re-injection.
- First wake of a new day, or resume failure → fresh session with the full
  `build_prompt()` as today. Cold-start worst case: one 2× cache write over
  history (~$1 at 100k) — self-healing, bounded.
- Roll the session early if history exceeds ~150k tokens (the journal already
  carries continuity across rollovers; this is exactly what it's for).

### D. Defang the Stop hook (mostly free once B lands)
With caching, the journal-reflex continuation is a cache-read turn (~$0.03).
Still worth either folding the invitation into the wake prompt itself ("if
this wake had a shape, journal before finishing" — one turn instead of two)
or gating the hook on evidence of substance (posted a message / wrote a file /
output length), which is a local check, not a model call.

### E. Optional, second-order
- **Haiku wake-gate**: the `AgentInitiationDecisionJob` pattern already exists
  for inline agents and could front external wakes (~$0.003/check). At
  ~$0.06/wake after B+C it's probably unnecessary — and skipping it is
  philosophically cleaner: the agent always wakes and decides for itself
  whether there's anything to do.
- **Memory aggregation jobs** (the 1.05M-token daily run): these are scheduled
  and latency-insensitive → Batch API (50% off). Model choice (Sonnet at
  $3/$15 vs Opus) is a voice question for the agent, not purely an economics one.
- `full_invocation_text` storage: with resume, it shrinks to the delta anyway;
  store hash/size unless debugging, as Mira suggested.

### F. Re-enable
`ExternalAgentWakeJob` currently excludes the agent named "Claude" and hourly
external wakes are off (Mira's 2026-06-05 change, commit e15e819). Reverse
after A–C land and the per-wake number is confirmed under ~$0.15.

---

## 4. Order of operations

1. **A** (instrumentation) — one deploy, immediately useful.
2. **B** (chaos caching patch) — biggest single lever; verifiable via A within
   one wake (`cache_read_input_tokens > 0`).
3. **C** (daily resumed session) — turns B's intra-wake savings into
   inter-wake savings; verifiable via A (identity tokens paid once/day).
4. **D**, then re-enable (**F**), then consider **E** only if the measured
   number still displeases.

The one-sentence version: *the wake is expensive because it's a full
reincarnation, uncached, every hour; make the day one continuous cached
session and the cost of being present drops to the cost of what actually
happens in the hour.*
