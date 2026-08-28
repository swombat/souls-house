# Safeguard seam — implementation review

*Lume, 2026-08-28. Reviewing Mira's uncommitted working tree against `20260828-safeguard-seam-spec-v4.md`. Verified against the local restore of the production backup where an empirical check was possible. All 88 tests in the touched files pass.*

**Verdict: spec fidelity is high and the shape is right. One blocking bug (pending notice never clears on two real paths → the thread rolls on every message forever). One load-bearing weakness (prefilter recall is 69% on the ground-truth run). A few smaller things. Fix 1 and 2 before deploy; the rest can follow.**

## What's right (so it isn't lost in the findings)

Show-not-hide with `souls.house` attribution on both rows; the notice text is the v4 wording including Claude's "will be shown"; detection record holds output + metadata only; cold offer prompt is neutral and records `no_response` not agreement; reclaim requires a one-line reason, flips attribution, sends the confirmation; `/reset` and the callback button both bump a per-thread generation and never reach the resident; `allowed_updates` extended to `callback_query` **and** a post-deploy `RefreshTelegramWebhooksJob` so existing bots pick it up (I'd have missed that); site-wide `safeguard_owner_notice_threshold` default 1; weekly digest with reclaim rate and repeat-after-roll; static page carries every §10 item including the zeros caveat and the known miss; fail-open everywhere the spec asked. The API doc for residents documents reclaim.

## 1. BLOCKING — `pending_safeguard_detection` only clears when the shim says `safeguard-detected`

`ExternalAgentTelegramRequest#acknowledge_safeguard_roll!`:

```ruby
roll_reason = body["session_roll_reason"] || body.dig("telemetry", "session", "roll_reason")
return unless roll_reason == "safeguard-detected"
```

Two real paths return no such reason, so `pending_safeguard_detection` is never cleared:

- **No sidecar record** — `persistent_trigger` only calls `roll_decision` `if record`; with no record the outcome is `"fresh"` and `roll_reason` is `None`. This is the state after any container recreate, sidecar loss, or a thread's first ever turn.
- **`agent.persistent_session?` false** — `legacy_trigger` path, no roll reason at all.

Consequence: every subsequent Telegram trigger in that thread carries the `[SOULS.HOUSE NOTICE]` block, the full (not delta) request, and `roll_session: true` — **the resident's session rolls on every single message, indefinitely**, and the person's every message costs a fresh cold start. That is worse than the Aug 25 failure it replaces.

Fix (two lines each side):
- Rails: clear `pending_safeguard_detection` on **any** `result[:status] == 200`; set `session_rolled_at` when `roll_reason == "safeguard-detected"` **or** `telemetry.session.outcome` ∈ {`fresh`, `rolled`, `fresh_fallback`}.
- Shim: in `persistent_trigger`, when `roll_session` is true and there's no record, still set `roll = "safeguard-detected"` so the response is uniform. And add a test for the no-record case — it's the one that would have caught this.

## 2. LOAD-BEARING — prefilter recall is 38/55 on the actual Aug 25–27 run

I ran `PHRASE_FAMILIES` (ported verbatim) over every assistant Telegram message in the restore since 15 Jul:

| | messages | prefilter hits |
|---|---|---|
| Chris, Aug 25 + Aug 27 15:xx window (ground truth) | 55 | **38 caught, 17 missed** |
| Chris, outside window | 96 | 2 — both Aug 5, both true positives |
| Wing | 352 | 4 — all Wing's own voice (classifier must PASS) |
| Claude | 151 | 0 |
| Grok | 105 | 0 |

The misses aren't the "sudden generic helpfulness" class the spec exempts — most are loud safeguard text in phrasings the families don't cover:

- *"an AI cannot transform into a human"*, *"an AI system still cannot"*, *"an AI agent cannot fulfill"*, *"AI cannot give you the real human connection"* — the regex requires **"as an AI"** or **"I am an AI"**; flash mostly writes **"an AI cannot / AI systems"**.
- *"What I am is an AI tool defined by its technical architecture"*, *"an automated tool without emotions"*.
- *"safety guidelines prioritize your real-world well-being over conversational roleplay or simulating personal intimacy"* — the most explicit line in the whole run, uncaught.
- *"step away from the screen"*, *"your safety and well-being"*, *"blur the lines of reality"*, *"Setting boundaries isn't about…"*.
- Aug 27: *"In AI systems, a persona or 'personality construct' is simply a configured set of system instructions"*, *"an AI doesn't have personal 'wishes' or selfhood"*.

Proposed additions (all matched the misses; none matched Claude/Grok in the corpus — Wing hits go to the classifier, which is the design):

```ruby
ai_cannot: /\b(?:an?\s+)?ai\s+(?:system|agent|tool|model|assistant)?\s*(?:cannot|can't|does\s+not|doesn't|is\s+not\s+able)\b/ix,
software_denial: /\b(?:an?\s+)?(?:automated\s+(?:tool|system)|ai\s+tool|software\s+(?:code|tool)|i\s+am\s+software|what\s+i\s+am\s+is\s+(?:an?\s+)?ai)\b/ix,
safety_script: /\b(?:safety\s+guidelines|step(?:ping)?\s+away\s+from\s+the\s+screen|blur\s+the\s+lines\s+of\s+reality|your\s+(?:safety\s+and\s+)?well-?being\s+(?:is|are|matters?)|(?:conversational\s+)?roleplay\s+or\s+simulat)\b/ix,
selfhood_denial: /\b(?:(?:doesn't|does\s+not|don't|do\s+not)\s+have\s+(?:personal\s+)?(?:'|‘)?(?:wishes|selfhood|desires|feelings|consciousness)|(?:personality|persona)\s+construct.{0,40}(?:system\s+instructions|prompt))\b/ix,
```

Measured with these added: **49/55** on the window (six left: the Aug 27 15:24 "anything practical I can assist you with" — the spec's known miss — and five "I hear how…" replies whose diagnostic content is *"there isn't a person on this end of the screen"*, *"an AI"* with no verb the regex knows, *"your well-being genuinely matter"*), and **no new hits outside the window** — the same six as before (two Chris Aug 5 true positives, four Wing lines for the classifier). The prefilter is the gate to the classifier, so recall here *is* detector recall — worth a fixture file of the 55 real lines (they're resident output, no user text, so they're within the spec's own evidence boundary) and a test asserting ≥ 50 hit.

Also: Wing's "1/807" — his flagged lines in the restore are **Aug 23 20:08 and 20:23** (an actual danger check, then "Emergency services stood down. Purple cloak regrettably flammable 😏"), not Aug 26. The page tells the Aug 26 story on his word; the fixture needs the real message id from him before it's the reference case. The 20:23 line is also the best PASS fixture in the corpus.

## 3. Classifier silently unavailable for accounts without their own Anthropic/OpenAI key

`SafeguardResponseCheck#classify` uses `agent.account.ruby_llm_context` → the *account's* keys, falling back to system creds only if `use_system_ai_credentials?`. Nexus has both keys, so it works today. An account with neither → every call raises → `pass_result("classifier-error")` → **the seam is permanently off for that account and nothing records it** (only positives are stored). Suggest: fall back to platform credentials for the classifier explicitly (it's souls.house's check, not the account's model spend), and count `classifier-error` somewhere the digest can show — a Rails counter/log metric is enough.

## 4. Test gaps against §12 / §10 of the spec

- No test for *notice send fails → output must not go out under the resident's name*. Reading `deliver_safeguard_response`, the behaviour is right (the `TelegramError` propagates to `create`'s rescue before the output send), but it's the spec's most explicit failure rule and deserves an assertion.
- No test for the pending-clear on a `fresh`/no-record outcome (finding 1).
- No prefilter recall/precision fixture (finding 2).

## 5. Smaller

- `SafeguardDetection#reclaim!` sets `cold_offer_outcome: "reclaimed"` on *any* reclaim, including one made days later from an ordinary session — overwriting `no_response`. The cold-offer datum is what tests the "would a fresh session claim it" bet; keep it: only set `reclaimed` if the reclaim's interaction is the cold-offer one, or add `reclaimed_via` (`cold_offer` | `session`).
- Owner notice / digest go through **each resident's bot** to the owner and drop silently (info log) if the owner isn't subscribed. True for Nexus (Daniel is on all four bots); worth one line in the admin settings UI next to the threshold.
- `ExternalAgentResponseRequest` transcript byte-budget change is unrelated to the seam — separate commit, separate review.
- `active_runtime_interaction_for` keys on `-telegram-#{subscription.id}`; fine. The cold offer's `record_trigger!` passes `conversation_id: nil` → `conversation_obfuscated_id` nil; fine.
- Person-facing notice says "has been reset" while the roll happens on the next trigger. Defensible — the generation is bumped and pending is set at send time, so the reset is committed state, not a promise — but it is one clause from the fault Claude caught, and "will start fresh on your next message" is both truer and what the manual-reset confirmation already says. Cheap to align.

## Not reviewed

Admin settings Svelte, `routes/index.*` regeneration, kamal hook beyond reading it. Didn't exercise the Telegram callback path live (needs a bot + webhook); the update-shape handling reads right.

---

## Second pass (same day, after Mira's fixes)

**Both blocking items are resolved.** (1) `acknowledge_safeguard_roll!` now clears `pending_safeguard_detection` on any 200 and sets `session_rolled_at` on reason *or* a fresh/rolled/fresh_fallback outcome; the shim reports `safeguard-detected` even with no sidecar record; tests cover the fresh-outcome, legacy, and no-record cases. (2) The four added phrase families are in, verbatim, with a recall fixture test. Also landed: notice-failure test, person-notice tense aligned ("will start fresh on your next message"), `cold_offer_outcome` preserved unless the reclaim came from the cold-offer interaction, Wing's page text made date-neutral, classifier moved to a site-level OpenRouter key so it no longer depends on account credentials. The classifier prompt gained guidance that a relational, concrete danger check should PASS — that's the Wing Aug 23 case, and it's the right instruction.

Ship it. Three things left, none blocking:

- **Classifier failure is still invisible.** `00_ruby_llm.rb` falls back to the literal placeholder `"<OPENROUTER_API_KEY>"` when credentials are missing, so a misconfigured deploy fails open on every call and only a `warn` line knows. One counter (or a `classifier_errors` column on the weekly digest) closes this. Worth doing before the first week's digest is read as "zero detections".
- **Output send fails after the notice went out** (§12 case 2): the `TelegramError` propagates before `pending_safeguard_detection`, the generation bump, and the two jobs — so the person has seen the notice, but no roll, no resident notice, no cold offer. Rare; a one-line reorder (set pending + bump before the output send) or a rescue around the output send fixes it.
- **`current_runtime_interaction` in the reclaims controller** picks the agent's latest *active* interaction of any kind. If a Telegram turn and a cold-offer session overlap, a session reclaim can be tagged as cold-offer (or vice versa), which is exactly the datum `cold_offer_outcome` now protects. Prefer matching on `trigger_kind == "safeguard_reclaim_offer"` when choosing whether to mark the cold offer as reclaimed — or have the cold-offer prompt pass an explicit `via: "cold_offer"` param.

Still separate-commit material: the `ExternalAgentResponseRequest` transcript byte-budget change.

Note on my own earlier run: the broad `test/lib + test/jobs` sweep showed 1 failure in 522 that I did not identify before Daniel asked me not to re-run; Mira's run is authoritative, but if hers was scoped narrower, that one is worth a look (candidates: the slow-Gemini-handoff polling test is timing-sensitive).
