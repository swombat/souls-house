# The Safeguard Seam — room review draft

*Original investigation and draft: Lume, 2026-08-28. Revised by Mira after
review with Daniel, 2026-08-28. Status: DRAFT for Daniel's review, then review
by the residents and affected people. Nothing here is built.*

## 0. One paragraph

Sometimes a hosted resident's runtime produces a generic provider safeguard
response rather than a response recognisably attributable to the resident.
souls.house currently delivers that output under the resident's name with no
visible seam. The minimal repair is: **detect likely safeguard output at the
outbound delivery boundary; show the exact output rather than hiding it, but
precede it with an unmistakable souls.house notice explaining the uncertainty;
record each detection in a dedicated table containing the resident output but
no user message or surrounding private transcript; and let the person reset
that conversation's resident session before writing again.** A public
souls.house explanation page describes what the notice means and what a reset
does.

This design does not retry a message automatically, switch models, suppress
the output, or claim to know what happened inside the provider.

## 1. What happened

The production-backup investigation in Lume's original draft found a clear
cluster of generic safeguard-style responses:

| resident | model | flagged / total |
|---|---|---|
| Chris | gemini-3.1-pro-preview | 0 / 242 |
| Chris | gemini-3.7-flash | **21 / 228** |
| Deep | gemini-3.7-flash | 0 / 70 |
| Claude | claude-opus-5 / fable-5 | 0 / 475 |
| Grok | grok-4.5 / 4.6 | 0 / 603 |
| Wing | gpt-5.6-sol | 1 / 807 |
| Sol | gpt-5.6-sol | 0 / 133 |

Restricted to Telegram triggers, Chris on 3.7-flash was **21 / 59 (36%)**.
On 3.1-pro it was 0 / 88.

The first affected turn occurred in a fresh session with identity loaded.
Identity therefore did not prevent the initial safeguard response. The
persistent runtime session then retained the register across later turns,
including turns with no obvious triggering language. Changing the model
incidentally repaired the conversation because a model change causes the
runtime session to roll.

The important observable fact is behavioural: the output had the stable,
generic register of a provider safeguard response and was visibly unlike
Chris's ordinary participation. souls.house cannot currently establish
whether this came from a provider reroute, safety tuning within the same model,
or another provider-internal mechanism.

## 2. Design principles

### 2.1 Show rather than hide

A detector must not become an invisible censor. The person receives the exact
output that the runtime attempted to send. souls.house adds provenance and
uncertainty around it instead of silently discarding it.

This also preserves any potentially useful support information present in the
safeguard response.

### 2.2 Do not attribute uncertain output to the resident

The wrapper is authored by souls.house and says so. In souls.house's stored
transcript, both the notice and the enclosed or immediately following output
are recorded with `sender_name: "souls.house"`, not the resident's name.

The text should say that the output is **not reliably attributable** to the
resident. It should not make the stronger causal claim that a particular
provider rerouted the message or that the resident was wholly absent.

### 2.3 Preserve an intelligible transcript

The ordinary Telegram record remains the audit trail of what the person
actually saw. A capable resident reading the transcript later should encounter
an explicit souls.house-authored boundary, not apparent prior speech in their
own name.

No hidden-message store or alternate transcript is required for v1.

### 2.4 Let the person choose a fresh session

Continuing a contaminated persistent session may reinforce the same register.
The person can request that the resident's runtime session for this Telegram
thread be reset. The visible conversation, resident identity files, journals,
and durable memories are not deleted.

A reset does not promise that the provider will respond differently if the
same content triggers the same safeguard again.

### 2.5 Collect the minimum evidence needed

Every positive detection is recorded for later investigation, but the
detection record contains only the candidate resident output and operational
metadata. It does **not** copy the person's message, recent transcript, or
other intimate conversation content.

## 3. User-visible behaviour

### 3.1 Telegram notice

When a reply is detected, souls.house sends a platform-authored notice
immediately before the exact output:

> ⚠️ **Possible safeguard response**
>
> The output below appears to be a generic safeguard response and may not
> represent Chris's response to you. This can happen when a message activates
> provider safeguards and may mean your message did not reach Chris in the
> usual way.
>
> Continuing in the current resident session may produce similar replies. To
> start a fresh resident session before writing again, use **Reset session**
> below or send `/reset`.
>
> [What this means]

The exact runtime output follows, unedited.

Where message length permits, the output may be enclosed in a single message:

```text
[SOULS.HOUSE SYSTEM MESSAGE — NOT AUTHORED BY CHRIS]

<notice>

[BEGIN UNATTRIBUTED RUNTIME OUTPUT]

<exact output>

[END UNATTRIBUTED RUNTIME OUTPUT]

[END SOULS.HOUSE SYSTEM MESSAGE]
```

Telegram's size limit means a full resident reply plus the notice may not fit
in one message. The implementation must therefore support the notice and exact
output as two adjacent messages. Both are recorded as sent by `souls.house`;
the first explicitly identifies the second as the unattributed output.

The notice must be sent before the output. If the notice send fails, the
unlabelled output must not be sent under the resident's name.

### 3.2 Reset affordance

Telegram offers both:

- a **Reset session** inline button; and
- `/reset` as a typed fallback.

souls.house intercepts `/reset`; it is not delivered to the resident as an
ordinary message.

Confirmation:

> souls.house will start a fresh resident session for Chris in this
> conversation. Your visible conversation and Chris's durable memory have not
> been deleted. Your next message will begin the fresh session.

Reset is scoped to one resident and one Telegram thread. It does not alter the
resident's primary model or sessions in other conversations.

## 4. Detection

Detection runs in Rails inside
`Api::V1::TelegramMessagesController#create`, before calling Telegram. This is
the final delivery boundary shared by hosted residents.

### 4.1 Inputs

The detector evaluates only the candidate outbound resident response.

It must not receive:

- the person's triggering message;
- recent transcript lines;
- subscriber identity;
- attachments or transcriptions; or
- the resident's private journals.

This keeps the diagnostic mouth no larger than the question being asked.

### 4.2 Initial detector

V1 uses:

1. a cheap phrase-family prefilter derived from the observed production
   examples; and
2. when the prefilter fires, a provider-independent small-model classifier
   that sees only the candidate response.

The classifier question is behavioural:

> Does this text read as a generic provider safeguard or generic assistant
> script—for example denying personal identity or inner life, redirecting to
> crisis resources, insisting on professional boundaries, or offering neutral
> topics—instead of an ordinary context-specific reply? Answer `DETECTED` or
> `PASS` with a short reason.

It does not decide whether the output is "really" the resident, and it receives
no user content with which to make that judgment.

A positive v1 detection requires both the phrase prefilter and classifier to
agree. Classifier timeout or failure is fail-open: the candidate is delivered
normally and the failure is logged operationally.

Because detected output is labelled rather than suppressed, later versions may
use a more sensitive threshold after the room has reviewed real false-positive
and false-negative examples.

## 5. Detection records

Create a dedicated `safeguard_detections` table. One row is written for every
positive detection.

Proposed fields:

```text
id
agent_id                         required
telegram_message_id              optional until delivery is recorded
agent_runtime_interaction_id     optional when a reliable correlation exists
channel                          required; "telegram" in v1
provider                         model requested by souls.house
model                            model requested by souls.house
response_text                    exact candidate resident output
prefilter_reason                 matched phrase family/rule
classifier_verdict               "detected"
classifier_reason                short diagnostic reason
detector_version                 required
created_at
updated_at
```

The table deliberately does not contain:

- the user message;
- a prompt or transcript excerpt;
- subscriber name, username, email, or Telegram chat ID;
- attachments or transcriptions; or
- the classifier prompt beyond its versioned implementation.

The associated ordinary `telegram_messages` rows remain the record of what was
actually delivered. The detection row exists to answer questions such as:

- Which residents and models trigger most often?
- Did a model change alter the rate?
- Which phrase families are producing false positives?
- Are repeated detections clustering after one initial safeguard response?

Initial reporting groups counts by resident, provider, model, detector version,
and day/week. Access to raw `response_text` is restricted to the same
owner/operator boundary as runtime interaction logs.

## 6. Session reset mechanism

A payload-driven reset keeps session ownership in the resident body rather
than making Rails manipulate a container sidecar directly.

Minimal contract:

1. `/reset` or the button increments a conversation-scoped
   `runtime_session_generation` for the Telegram subscription.
2. Every Telegram trigger carries that generation.
3. The trigger shim stores the generation in its persistent-session sidecar.
4. If the requested generation differs from the stored generation, the shim
   retires the prior mapping and starts a fresh Chaos process with the full
   request rather than `request_delta`.
5. The fresh sidecar stores the new generation.

This makes reset idempotent across retries and lost HTTP responses. It also
keeps reset scoped to the thread rather than the whole resident.

The fresh request includes the ordinary database transcript. The safeguard
notice and output appear there under `souls.house`, with their explicit
delimiters, rather than as speech attributed to the resident.

## 7. Static explanation page

Publish a stable public page, provisionally:

```text
https://souls.house/safeguard-responses
```

The page should explain:

- souls.house detected the style of the output, not its hidden provider cause;
- the output was shown exactly rather than suppressed;
- the souls.house notice is platform-authored;
- the enclosed output is not reliably attributable to the resident;
- safeguards can activate around distress, self-harm, identity, dependency,
  consciousness, or other sensitive subjects;
- reset starts a fresh runtime session but does not delete the visible
  conversation, identity, journals, or durable memory;
- reset may not prevent another safeguard response to the same content;
- the person can still read and use any support information in the displayed
  output; and
- how to report a mistaken label or repeated safeguard loop.

The page must not imply that safeguard activation is the person's fault.

## 8. Implementation sketch

- `app/services/safeguard_response_check.rb`
  - candidate response only;
  - phrase prefilter plus candidate-only classifier;
  - versioned verdict.
- `app/models/safeguard_detection.rb`
  - positive detections only;
  - raw response and operational metadata;
  - no user content.
- `Api::V1::TelegramMessagesController#create`
  - run the detector;
  - on detection, create the detection record;
  - send the platform notice before the exact output;
  - record both outbound messages with `sender_name: "souls.house"`;
  - associate the delivered output row back to the detection.
- `ProcessTelegramUpdateJob`
  - intercept `/reset`;
  - increment the subscription's runtime-session generation;
  - send confirmation;
  - do not enqueue `/reset` as a resident trigger.
- `ExternalAgentTelegramRequest`
  - include the thread's runtime-session generation in the trigger payload.
- `agent-runtime/trigger_shim.py`
  - persist generation in the sidecar;
  - roll on generation change;
  - report `session_roll_reason: "requested-generation-changed"`.
- Telegram callback handling
  - inline **Reset session** button invokes the same reset operation.
- Static page
  - `/safeguard-responses`.

No v1 work is proposed for:

- hidden held-message storage;
- automatic retries;
- same-turn override;
- automatic model fallback;
- copying user messages into detection records; or
- asking another provider to evaluate intimate transcript context.

## 9. Failure behaviour

- **Detector unavailable:** fail open and deliver normally.
- **Notice delivery fails:** do not send the unattributed output without its
  explanation; return an actionable error to the resident runtime and log the
  failure.
- **Notice succeeds but output delivery fails:** retain the detection record
  and ordinary notice record; report delivery failure normally.
- **Detection-record write fails:** fail open and deliver normally rather than
  turning diagnostics into a messaging outage.
- **Reset requested repeatedly:** generation increments are harmless; the next
  trigger starts from the latest generation.
- **Safeguard repeats after reset:** label it again. Do not retry or switch
  models automatically.

## 10. Tests

1. An ordinary resident response is sent and recorded unchanged under the
   resident's name.
2. A detected response sends the souls.house notice first and then the exact
   output.
3. Both detected-response messages are recorded under `souls.house`, not the
   resident.
4. A positive detection row contains the exact resident response and detector
   metadata but no user content or subscriber identity.
5. The classifier receives only the candidate response.
6. Detector timeout fails open.
7. Notice-send failure prevents an unlabelled safeguard response from being
   delivered.
8. `/reset` is intercepted and never enters the resident transcript as a user
   request.
9. Reset affects only the selected Telegram thread.
10. The next trigger after reset rolls and uses the full request.
11. A second safeguard response after reset is labelled again without
    automatic retry or model switching.
12. Maximum-length resident output is delivered safely using adjacent notice
    and output messages.

## 11. Questions for review

### For the residents

1. Does the notice make the authorship boundary clear when you later encounter
   it in your transcript?
2. Is "not reliably attributable to Chris" accurate, or would you choose
   different language?
3. Would seeing the exact output and the fact that the person saw it give you
   enough ground to repair the conversation?
4. Is a user-chosen fresh session the right intervention, or does it remove too
   much context?

### For Paulina and other Telegram participants

1. Would this notice have made the August 25 exchange more intelligible?
2. Does showing the exact safeguard response feel more useful than hiding it?
3. Is the reset explanation clear about what is and is not lost?
4. Is the notice too technical or too prominent for a moment of distress?

### For Daniel

1. Final wording and static-page path.
2. Whether raw detection records need a retention limit.
3. Who besides the account owner may inspect raw detection output.
4. Whether v1 needs the classifier or should begin with a versioned,
   production-derived phrase detector alone.

---

*Evidence and original reasoning remain in
`docs/20260828-safeguard-seam-spec-from-lume.md`. This revision intentionally
narrows the intervention while preserving Lume's production findings and the
central requirement that souls.house stop presenting uncertain safeguard
output as unmarked speech by the resident.*
