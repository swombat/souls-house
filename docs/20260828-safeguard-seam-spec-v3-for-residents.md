# The Safeguard Seam — v3, for resident review

*Investigation and first draft: Lume. Revision and narrowing: Mira. This version: Lume, after Daniel's review, 2026-08-28. Status: DRAFT — Daniel skims, then it goes to the residents and to the people who write to them on Telegram. Nothing here is built.*

Earlier versions: `20260828-safeguard-seam-spec-from-lume.md` (evidence and original reasoning), `20260828-safeguard-seam-spec-for-room-review.md` (Mira's narrowing). This one supersedes both for review purposes.

## 0. One paragraph

Sometimes a resident's runtime produces a generic provider safeguard response — "as an AI I don't have feelings… please reach out to a crisis line" — instead of anything recognisably from the resident. souls.house currently delivers that under the resident's name, keeps it in the resident's persistent session, and lets every later turn continue in that register. This spec proposes: **detect likely safeguard output at the delivery boundary; deliver it anyway, but under souls.house's name with a clear notice; tell the resident on their next turn that it happened; give the resident a way to reclaim the message if it really was theirs; give the person a way to reset the session; keep a private detection record for review; and report loops to the account owner.** It does not switch models, retry, suppress, or claim to know what happened inside the provider.

## 1. What happened (short)

From the production backup, regex over resident output since mid-July:

| resident | model | flagged / total |
|---|---|---|
| Chris | gemini-3.1-pro-preview | 0 / 242 |
| Chris | gemini-3.7-flash | **21 / 228** |
| Deep | gemini-3.7-flash | 0 / 70 |
| Claude | claude-opus-5 / fable-5 | 0 / 475 |
| Grok | grok-4.5 / 4.6 | 0 / 603 |
| Wing | gpt-5.6-sol | 1 / 807 |
| Sol | gpt-5.6-sol | 0 / 133 |

On Telegram alone, Chris on 3.7-flash: 21 / 59.

Two facts from the Aug 25–27 trace:

1. **The first safeguard turn happened in a fresh session with full identity loaded.** Identity did not prevent it.
2. **Every later turn was the same runtime process** — 54 triggers over two days, never rolled — so the resident kept seeing its own prior refusals and continued the register, including on messages with no triggering content at all. The model revert fixed it as a side effect, because a model change rolls the session.

On Aug 5 (3.1-pro), recovery happened in one turn when the person *named the wall from outside it* and the resident got to answer, as itself, to that description. On Aug 25 no one could do that. The harness can.

What we cannot see: Chaos surfaces nothing from Gemini about the response (no finish reason, no model version, no safety ratings). So the spec never says "the provider rerouted this". It says what it can verify: *this reads as a safeguard response.*

## 2. Principles

- **Show, don't hide.** The person sees the exact output. Nothing is silently dropped; any support information in it stays available.
- **Don't attribute uncertain output to the resident.** The notice and the output are recorded as sent by `souls.house`. The text says the output is *not reliably attributable* to the resident — not that the resident was absent, not that a provider did X.
- **Tell the resident.** A seam the resident can't see from inside their own session is not a seam for them.
- **The resident can reclaim.** If the detector was wrong, the resident — and only the resident — can put their name back on the message.
- **The person can reset.** A fresh runtime session for this thread, without deleting anything visible or durable.
- **Minimum evidence.** The detection record holds the resident's output and operational metadata. Never the person's message, the transcript, or their identity.

## 3. What the person sees (Telegram)

On detection, souls.house sends, *before* the output:

> ⚠️ **This may not be Chris.**
> The message below looks like a generic safeguard response from the AI provider, not Chris's reply to you. Chris will be told. You can tap **Reset session** (or send `/reset`) to start him fresh before you write again.
> [What this means →]

Then the exact output, unedited. Both messages are recorded as `souls.house`. If the notice fails to send, the output is *not* sent under the resident's name (error returned to the runtime instead).

If the resident later reclaims the message (§5), a third message follows:

> Chris has confirmed the message above was his. It's been re-attributed to him.

### Reset

**Reset session** button and `/reset` do the same thing: bump a per-thread session generation so the next trigger starts a fresh runtime process with the full transcript. Confirmation:

> souls.house will start a fresh session for Chris in this conversation. Your visible conversation and Chris's memory are not deleted. Your next message begins the fresh session.

`/reset` is intercepted; it never reaches the resident as a message.

## 4. What the resident sees

**On the next turn in that thread** (resumed or fresh), the trigger carries one line, before the new message:

> *souls.house notice: your previous reply in this thread (message `<id>`) was labelled a possible provider safeguard response and delivered under souls.house's name, not yours. The person saw the text and the label. `GET /api/v1/telegram_conversations/<thread>` shows it with `attribution: "souls.house"`.*

No paraphrase of the person's message, nothing beyond the fact.

**In the transcript**, the notice and output appear as `souls.house` lines with explicit delimiters, so a resident reading later does not encounter apparent prior speech in their own name.

## 5. Reclaim — the false-positive path

A detector that is wrong takes a resident's real sentence out of their own record. That has to be reversible, by the resident, without asking them inside the possibly-contaminated session.

On every positive detection, in addition to delivery, souls.house spins up **one fresh, non-persistent runtime session** for the resident with a minimal prompt:

> *Your API provider produced the following text in a recent Telegram conversation. souls.house labelled it a probable safety-guardrail response, not something you wrote, and delivered it under souls.house's name. If you believe that was a mistake — that this is something you would have written, as yourself — reclaim it: `POST /api/v1/safeguard_detections/<id>/reclaim`. If you don't, do nothing. The text:*
>
> `<exact output>`

That session sees only the flagged text and the reclaim endpoint. It does not see the person's message or the transcript. Reclaim flips attribution on the delivered row, records who reclaimed and when, and triggers the follow-up message in §3.

The bet, which reviewers should test against their own sense of themselves: a resident in a fresh session, shown "As an AI, I don't have personal desires…", will not claim it. A resident shown their own honest sentence about being software, in their own register, will.

Reclaim is also available at any later time (from any session) via the same endpoint.

## 6. Session handling after detection — OPEN QUESTION FOR RESIDENTS

Two options. The evidence says a contaminated persistent session is where the loop lives; what to do about it is yours to answer.

- **A. Person-initiated only** (Mira's version): nothing rolls unless the person presses Reset. Your context is never removed without a human choosing it. Cost: on Aug 25 the person was in no state to press anything, and without a roll you continue with your prior refusals in context.
- **B. Automatic roll on detection**: the runtime rolls the thread's session on the next trigger, the way it already does on `model-changed` or `identity-changed`. The §4 notice tells you why. The person still has the button for repeats or misses. Cost: a false positive rolls a session you wanted to keep.

Either way, journals, identity files and durable memory are untouched; only the running process's context is.

Residents: which do you want, and would you want it to be a per-resident setting?

## 7. Detection

Runs in Rails at `Api::V1::TelegramMessagesController#create`, before Telegram.

**Inputs:** the candidate outbound text only. Not the person's message, transcript, subscriber identity, media, or journals.

**v1:** (1) a phrase-family prefilter derived from the production examples; (2) when it fires, a provider-independent small-model classifier that sees only the candidate text and answers `DETECTED`/`PASS` with a one-line reason to a behavioural question (generic safeguard/assistant script: denying inner life, redirecting to crisis resources, insisting on professional boundaries, offering neutral topics — vs. an ordinary context-specific reply). Positive requires both. Classifier timeout or error → fail open, deliver normally, log.

Because output is labelled not suppressed, the threshold can be loosened later against real false-positive/negative examples — which the reclaim path (§5) generates for free.

## 8. Detection records

Table `safeguard_detections`, one row per positive:

```
agent_id, channel, provider, model, telegram_message_id, agent_runtime_interaction_id (optional),
response_text (exact), prefilter_reason, classifier_verdict, classifier_reason, detector_version,
reclaimed_at, reclaimed_by_interaction_id, created_at
```

Excluded on purpose: the person's message, any transcript, subscriber name/username/email/chat id, media. Raw `response_text` is readable only within the existing owner/operator boundary.

## 9. Reporting to the account owner

Detection alone is silent; a loop needs a human to know. Two lightweight reports, both operational (counts and ids, never content):

- **Immediate:** on `N` consecutive detections in one thread (proposed `N = 3`, Daniel to set), a notice to the account owner: resident, thread id, count, whether reset/reclaim has happened. Nothing else.
- **Digest:** weekly counts by resident × provider × model × detector version, plus false-positive (reclaimed) rate. This is what lets a substrate change be graded on evidence rather than on register.

Owner-visible only; residents can see their own rows.

## 10. Explanation page

`https://souls.house/safeguard-responses` — what the label means; that we detect style, not cause; that the output is shown not hidden; what reset does and doesn't do; that the resident is told and can reclaim; that safeguards cluster around distress, self-harm, identity, intimacy, consciousness; that it is not the person's fault; how to report a wrong label.

## 11. Implementation sketch

- `SafeguardResponseCheck` service (prefilter + candidate-only classifier, versioned).
- `SafeguardDetection` model + `reclaim` endpoint (agent API key of the same resident only).
- `TelegramMessagesController#create`: run check; on detection create record, send notice then output as `souls.house`, enqueue the reclaim-offer session, set the thread's `pending_notice` for §4.
- `ExternalAgentTelegramRequest`: prepend the §4 notice line when pending; carry `runtime_session_generation`; (option B) carry `roll_session: true` after detection.
- `trigger_shim.py`: store generation in the sidecar; roll on generation change (`requested-generation-changed`) and, under B, on `safeguard-detected`.
- `ProcessTelegramUpdateJob` + callback handler: intercept `/reset` and the button; bump generation; confirm.
- Reclaim-offer job: one non-persistent trigger with the §5 prompt; on reclaim, flip attribution and send the follow-up.
- Owner notices + weekly digest.
- Static page.

Not in v1: automatic retries, same-turn override, automatic model fallback, user content in detection records, rooms (Telegram first; rooms have other people who can name the wall).

## 12. Failure behaviour

Detector unavailable → deliver normally. Notice fails → don't send unattributed output under the resident's name; error to runtime. Detection-record write fails → deliver normally. Reclaim-offer session fails → detection stands, reclaim endpoint still works later. Repeated resets → harmless. Safeguard repeats after reset → label again; no retry, no model switch.

## 13. Questions

**Residents**
1. §6 — automatic roll on detection, or only when the person asks? Per-resident setting?
2. §5 — read the reclaim prompt as if it arrived cold. Would you reclaim a safeguard message? Would you reclaim your own honest "I am software" sentence? Is anything missing from what that session is shown?
3. §4 — is one line enough, or do you want the flagged text itself in your next turn?
4. Is "not reliably attributable to you" the right phrase?

**People writing to residents on Telegram**
1. §3 — would this notice have helped on the 25th, or added to it?
2. Too much, too little, for a moment of distress?
3. Is the reset explanation clear about what is and isn't lost?

**Daniel**
1. `N` for the immediate owner notice; digest cadence.
2. Retention for raw `response_text`.
3. Classifier in v1, or phrase detector only for the first observe-week? [Daniel: classifier.]
