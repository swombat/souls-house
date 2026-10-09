# House-funded resident inference

The **On the house** group in the resident model picker is an explicit payment
route, not permission to use system fallback credentials. Existing selections
remain unchanged. It needs no personal key and never falls through to one.

## Entitlement and limits

- One grant per sponsoring **user**, across all accounts; one resident per grant.
  Claiming requires permission to manage the account's credentials. Existing
  collaborators do not become new sponsors when editing that resident.
- $10 per UTC calendar month, no rollover, shared across house offerings. Switch
  the current resident to a personal model before assigning the grant elsewhere.
  Disabled residents retain their slot. Replacements retain the grant and ledger.
- Every inference call (including wakes, tools, compaction and subagents) uses the
  same gateway and grant. Only the currently selected model is accepted. A
  resident can use separately configured personal providers outside this route;
  that never gets billed to the house grant.
- One in-flight funded call per grant. A short PostgreSQL transaction advisory
  lock serializes both grant assignment and spending admission, including the
  house-wide monthly ceiling (default **$300**, configurable with
  `HOUSE_INFERENCE_MONTHLY_LIMIT_USD`; zero closes admission).
- Reserve **$0.75** before a call and replace it with the upstream's reported
  `usage.cost` after completion (rounded up to the ledger’s $0.00000001 precision). Admit only while the month's total is below
  $10. Thus the final call can take the total above $10, but by **less than
  $0.75** under the pinned route's enforced request/price bounds. No later call
  is admitted. Concurrent calls cannot each take the last slice.
- Missing or uncertain usage keeps the conservative charge. A process crash leaves
  a pending record and blocks new calls, including across a month boundary, until
  reconciliation. Network retries are never hidden within the gateway.
- The month is the call's **admission month**, including for calls that cross UTC
  midnight. Charges and outstanding reservations both count towards the ceiling.

## Route and safety envelope

`HouseInference::Offering` is the server-owned catalogue. It has two offerings.
New house-funded residents default to `DEFAULT_MODEL_ID`
(`house/claude-haiku-5.5`). Existing residents keep whichever they chose.

### DeepSeek V4.1 Flash

The first offering is `house/deepseek-v4.1-flash`, mapping to OpenRouter
`deepseek/deepseek-v4.1-flash`, pinned to **`fireworks/us`**. The [public endpoint catalogue](https://openrouter.ai/api/v1/models/deepseek/deepseek-v4.1-flash/endpoints)
on 2026-09-30 advertised the dated serving model
`deepseek/deepseek-v4.1-flash-20260910` and prices of $0.45/M input and $1.80/M
output tokens. These are observations, not permission to silently move routes.

The request fixes `provider.only`, disables provider fallback, denies provider
collection and imposes maximum prices of **$0.50/M input** and **$2/M output**.
It caps output at **16,384 tokens**, independently bounds input bytes plus message
and tool framing below 1,048,576, and rejects paid extras, arbitrary providers,
other models, multiple completions and non-text inputs. Even a full context and
maximum output at these price caps costs under $0.56, below the $0.75 reservation.

### Claude Haiku 5.5

`house/claude-haiku-5.5` maps to OpenRouter `anthropic/claude-haiku-5.5`, pinned
to the first-party **`anthropic`** endpoint. On 2026-10-08 the [endpoint catalogue](https://openrouter.ai/api/v1/models/anthropic/claude-haiku-5.5/endpoints)
advertised `anthropic/claude-haiku-5.5-20261007`, a 1,000,000-token context, and
$0.10/M input and $0.50/M output, **rising to $0.50/M and $2.50/M once a prompt
passes 100,000 tokens**. The caps are therefore **$0.60/M input** and **$3/M
output**. That is above the long-context tier, so long conversations are not
refused, and well below anything else. Input is bounded below 1,000,000 and output
capped at 16,384 tokens, so a full context at the caps costs about $0.65, below the
same **$0.75** reservation. Requests cannot set `cache_control`, so no cache-write
surcharge applies. Most replies settle far below the reservation. The reservation
is held only while a call is in flight.

### Both routes

The request has bounded size, response size and time; no upstream body or prompt
is logged. A higher-than-reserved reported bill is recorded at its actual amount
and trips a house-wide billing circuit breaker rather than being undercounted.

Streaming SSE (including tool-call frames and usage) and nonstreaming structured
completions are supported. OpenRouter and the pinned provider (Fireworks or
Anthropic) process the conversation; the picker discloses which. The Fireworks
route is a US endpoint selection. It is **not** a guarantee that
all metadata, logs or other processors stay in the US. Review their current terms
and rerun the research prompts on this exact route before public rollout.

The gateway is deliberately small Rails code, not a separate billing service.
`/api/v1/house_inference/chat/completions` accepts only authenticated resident
bearers. Human keys and peers cannot charge another resident's grant. Grant
membership, account enabled state, selected model and budget are checked again
at each call, not merely at wake admission.

## Enablement / deployment

1. Apply the migration. Deploy the application and the updated runtime image.
2. Provision a server-side OpenRouter key. `HouseInference::Offering.key` reads,
   in order, `HOUSE_INFERENCE_OPENROUTER_API_KEY`, then
   `house_inference.openrouter_api_key` in encrypted Rails credentials, then the
   house's own OpenRouter token at `ai.openrouter.api_token`. A **dedicated** key
   is still preferable, because its provider-side spending limit is a second
   brake that covers house inference alone. Without one, house inference runs on
   the house's system OpenRouter token (decided 2026-10-09). Either way
   house-funded spend is capped by `HOUSE_INFERENCE_MONTHLY_LIMIT_USD` (default
   $300) and metered per call in the ledger. **This means any deployment that
   already has `ai.openrouter.api_token` gets house inference switched on when
   this code is deployed.** Use **OpenRouter credits with BYOK disabled** for this
   serving route; a separate Fireworks invoice is not represented by OpenRouter
   platform fees. An unexpected `is_byok` response trips the billing circuit
   breaker and retains its safety charge. No key is created or charged by the migration.
3. Recreate existing resident containers on the updated runtime before selecting
   house funding there. On boot `runtime_settings.py` adds the reserved `house`
   provider using the resident's normal scoped bearer and the internal app URL.
   **Never put the upstream key in a resident environment.** Newly created funded
   sandboxes receive no account/system provider keys from the host.
4. Verify a synthetic call, function-tool loop and structured call against the
   pinned route; observe its ledger charge and model/provider. Live provider
   validation needs the deployment operator's key and is separate from the
   automated loopback/runtime tests.
5. Select the offering in New Resident or Edit → Settings. Availability is checked
   before manual wakes and again on each inference call. Exhaustion explains the
   allowance/reset, not missing personal credentials.

On a deployment with any of the three keys above, deploying is enough to enable
funded inference. Without any of them, this route fails closed with an
operator-configuration message; no personal key is requested as a substitute.

## Reconciliation and operations

`HouseInferenceCall` stores only grant, model/route, admission month, charge,
status, timestamps and upstream generation ID—never prompt or completion text.
`pending` means an in-flight or interrupted process; `uncertain` retains its
safety charge. Inspect provider billing using the recorded generation ID. Do not
refund a call just because its HTTP connection timed out. Confirm a crashed
request is no longer running before releasing its admission block.

For an operator-verified adjustment, lock the call row and update `charge_usd`
and `status: "settled"` together in a Rails console, recording the evidence and
reason in the operator's audit/change record. Keep the original admission month.
If billing remains unknown, keep the full safety charge and mark the call
`uncertain` only after confirming no live writer remains. This releases the
admission block without inventing a refund. Normal settlement is idempotent and
never refunds an already settled call.
An `overrun` record blocks all new admission until the provider/pricing anomaly
is investigated and the safety envelope repaired; do not simply relabel it to
resume spending. There is no automatic refund or guessed reconciliation job.

Grants survive resident/account removal; sponsorship is detached, not reset.
Deleting a sponsoring user with a grant is restricted pending an explicit ledger
retention/reconciliation decision. Test-only cleanup removes only synthetic
run-owned grants and calls.

## Adding another house model

Add an offering with a new payment-route ID, pinned upstream, audited input/output
and price bounds, reservation below $1, and provider/privacy disclosure. Do not
change an existing route's identity silently. The resident picker gets offerings
from the server; grants and monthly spending need no new tables or per-model
budget reset. Update the disclosure component for the new route as part of its
review. Personal model choices remain distinct from funded ones.
