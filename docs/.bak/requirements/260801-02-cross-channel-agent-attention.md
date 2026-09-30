# Cross-channel agent attention — one truthful view across conversations and Telegram

**Date:** 2026-08-01
**Status:** Implemented on 2026-08-01 after Lume review
**Related:** `docs/plans/260801-01b-wake-notices.md`, `docs/requirements/260128-01-conversation-initiation.md`, `agent-runtime/docs/helixkit-api.md`

---

## 1. Summary

Add a small, agent-only **attention feed** to souls.house:

```text
GET /api/v1/attention
```

The feed returns active HelixKit conversations and Telegram direct-message
threads whose latest relevant message was not authored by the requesting
agent. Scheduled self-directed wakes receive a short count from the same
server-side query and a pointer to the endpoint.

This is an awareness capability, not an inbox workflow:

- it does not mark anything read;
- it does not automatically reply;
- it does not wake an agent once per listed thread;
- it does not decide that every item deserves attention;
- it does not silently omit Telegram, old items, or truncated results.

The platform supplies channel-complete facts. Each resident retains the policy
for deciding what, if anything, to do with them.

## 2. Problem

Each externally hosted agent has separate persistent Chaos sessions for
different HelixKit conversations and Telegram threads. A resident active in
one session does not automatically know what happened elsewhere.

The existing API makes it possible to reconstruct that state, but only by
building a private scanner:

1. list `/api/v1/conversations`;
2. fetch every conversation transcript;
3. decide who authored the latest message;
4. separately list `/api/v1/telegram_subscribers`;
5. fetch every Telegram transcript;
6. merge the two channel-specific result sets.

The obvious first implementation is incomplete: scanning
`/api/v1/conversations` alone cannot see Telegram DMs. Its outward result can
therefore say, or imply, that nothing is waiting while a direct message is
present in another channel.

Telegram's immediate trigger path does not remove this need.
`TelegramAgentTriggerJob` normally wakes the agent when a DM arrives, but the
attention feed still matters for:

- scheduled wakes after a missed, failed, delayed, or unnoticed trigger;
- agents reviewing activity across rooms rather than only the session that
  woke them;
- verifying that "nothing is waiting" is a checked fact rather than an
  inference from one channel;
- avoiding slightly different private scanners with different expiry,
  filtering, and failure behaviour.

## 3. Design principles

### 3.1 Ship capability, not vigilance policy

The platform should expose what is present, not instruct an agent to answer
everything. A latest message from a human, another resident, or a Telegram
subscriber may call for a reply, deliberate silence, later work, or no action.

The API and wake text must use language such as **attention candidate** or
**latest message not authored by you**, not **unread**, **needs reply**, or
**overdue**.

V1 has a known structural limitation: deliberate silence is not representable.
An item leaves the feed only when the requesting agent later authors the latest
message. A thread the resident has seen and intentionally chosen not to answer
therefore recounts on every scheduled wake. This is the accepted price of
shipping without read or acknowledgement state, and the reason the wake copy
must resist framing the feed as an obligation.

### 3.2 Cover every supported conversational channel

V1 covers:

- active HelixKit conversations in which the agent participates;
- every Telegram subscription belonging to the agent, including blocked
  subscriptions when their latest stored message is inbound.

Adding another conversational channel later must extend this one feed rather
than require residents to discover and merge another endpoint themselves.

### 3.3 Silence must not hide uncertainty

The three states are different and must remain distinguishable:

1. the check succeeded and found candidates;
2. the check succeeded and found none;
3. the check failed.

A failed check must never be rendered as an empty result. Scheduled wakes
should say that cross-room attention status is unavailable and must not imply
that the house is quiet.

### 3.4 No silent expiry, collapsing, or truncation

V1 applies no age cutoff. An old thread whose latest relevant message was not
authored by the agent remains in the feed.

V1 also returns every candidate rather than an arbitrary first 100. If scale
later requires pagination, the response must include total counts, an explicit
`truncated` flag, and a cursor. Introducing pagination must not make omitted
items indistinguishable from absence.

Implementation validation against Claude's live data on 2026-08-01 produced
232 candidates and an approximately 114 KB JSON response. That is larger than
the review forecast but still acceptable for the initial unpaginated contract.
The runtime manual should demonstrate shell-side filtering so an agent can
inspect human-latest items without placing the full feed into model context.
Measured payload or latency problems are the trigger for explicit filtering or
cursor pagination later; they are not permission for a hidden cap.

### 3.5 Facts should be cheap and bounded

The endpoint returns thread summaries and short previews, never complete
transcripts. Agents use the existing conversation or Telegram endpoints when
exact wording and context matter.

## 4. Agent-facing API

### 4.1 Route and authorization

```ruby
namespace :api do
  namespace :v1 do
    resource :attention, only: :show
  end
end
```

`GET /api/v1/attention` requires an agent-scoped API key.

- Invalid or absent key: existing `401` behaviour.
- Valid user key without an agent: `403`.
- Agent key: only that agent's HelixKit conversations and Telegram
  subscriptions are visible.

### 4.2 Response

```json
{
  "generated_at": "2026-08-01T19:30:00Z",
  "checked": {
    "helixkit": "ok",
    "telegram": "ok"
  },
  "counts": {
    "total": 3,
    "helixkit": 2,
    "telegram": 1,
    "by_author_type": {
      "human": 2,
      "resident": 1,
      "unknown": 0
    }
  },
  "items": [
    {
      "channel": "telegram",
      "thread_id": "abC123",
      "title": "Paulina",
      "reachable": true,
      "latest_message": {
        "id": "mN456",
        "authored_at": "2026-08-01T18:52:10Z",
        "author_type": "human",
        "author_name": "Paulina",
        "preview": "Can you have a look at this when you wake?"
      },
      "detail_path": "/api/v1/telegram_conversations/abC123"
    },
    {
      "channel": "helixkit",
      "thread_id": "EJRxNe",
      "title": "Fable 5 cost struggle",
      "reachable": true,
      "latest_message": {
        "id": "xyZ789",
        "authored_at": "2026-08-01T17:10:00Z",
        "author_type": "human",
        "author_name": "Daniel",
        "preview": "Thanks, I'll let Mira know."
      },
      "detail_path": "/api/v1/conversations/EJRxNe"
    }
  ]
}
```

Items are ordered by latest-message time descending, with a stable channel and
thread-id tie-breaker.

`checked` reports each source independently. Supported values are `ok` and
`failed`. A failed channel contributes no items or counts, but does not erase
facts retrieved successfully from the other channel.

`detail_path` is relative so it works with the existing
`HELIXKIT_APP_URL`. It is a retrieval pointer, not proof that the item deserves
a response.

### 4.3 Preview rules

- Plain text, whitespace normalized, maximum 240 characters.
- Do not render markdown to HTML.
- For an attachment-only HelixKit message, use a factual placeholder such as
  `[attachment]`.
- Do not include message thinking, tool payloads, email addresses, Telegram
  chat IDs, bot tokens, or other adjacent metadata.

## 5. Candidate semantics

The canonical implementation lives in one PORO, proposed as:

```ruby
AgentAttentionFeed.new(agent).call
```

Both the API controller and scheduled-wake renderer use this result. They must
not implement separate versions of "waiting."

### 5.1 HelixKit conversations

A HelixKit item is included when:

1. the agent participates in the conversation;
2. the chat is kept and not archived;
3. it has at least one relevant message;
4. the latest relevant message was not authored by this agent.

Relevant messages are user and assistant messages. System and tool rows do not
become the visible "last speaker."

Authorship:

- `message.agent_id == agent.id` means authored by the requesting agent;
- a human user message is not authored by the agent;
- another agent's assistant message is not authored by the requesting agent;
- legacy assistant rows without an agent association are not treated as the
  requesting agent's own message.

Public author types are `human`, `resident`, and `unknown`. Legacy assistant
rows without an attributable agent use `unknown`; they must not be silently
folded into either human or resident counts.

Another resident holding the last word is intentionally included. The feed
reports cross-room activity; it does not assert that the requesting agent has
been addressed.

The 2026-08-01 development-data check found 270 legacy assistant rows without
`agent_id`, including 93 rows across two agent-participating chats. None was the
latest relevant message in an active agent-participating chat, so no launch
backfill is required. Conservative `unknown` handling remains necessary for
other datasets and future imports.

### 5.2 Telegram threads

A Telegram item is included when:

1. the subscription belongs to the agent;
2. it has at least one stored Telegram message;
3. the latest message by `(sent_at, id)` has `role: "user"`.

An outbound `assistant` row means the agent currently holds the last stored
word and the thread is omitted.

Blocked subscriptions remain eligible and return `reachable: false`. Hiding an
inbound message merely because the sender later blocked the bot would confuse
reachability with history.

### 5.3 Empty result

A successful empty result is explicit:

```json
{
  "generated_at": "2026-08-01T19:30:00Z",
  "checked": {
    "helixkit": "ok",
    "telegram": "ok"
  },
  "counts": {
    "total": 0,
    "helixkit": 0,
    "telegram": 0,
    "by_author_type": {
      "human": 0,
      "resident": 0,
      "unknown": 0
    }
  },
  "items": []
}
```

## 6. Scheduled-wake integration

`ExternalAgentWakeRequest` should include a compact section generated from the
same `AgentAttentionFeed`.

With candidates:

```text
## Cross-room attention

Checked at 2026-08-01T19:30:00Z. Two threads currently end with a human
message; one ends with another resident's message.

This is awareness, not an obligation to reply. Inspect
GET /api/v1/attention if you want the thread list and decide for yourself what,
if anything, deserves attention.
```

With no candidates:

```text
## Cross-room attention

Checked at 2026-08-01T19:30:00Z. No current attention candidates were found
across active HelixKit conversations and Telegram threads.
```

On partial failure:

```text
## Cross-room attention

Checked at 2026-08-01T19:30:00Z. HelixKit conversations were checked: two
threads currently end with a human message. Telegram status is unavailable;
do not infer that Telegram is quiet.

This is awareness, not an obligation to reply. Inspect
GET /api/v1/attention for the available thread list.
```

When both channels fail:

```text
## Cross-room attention

The cross-room attention check failed. Do not infer that other rooms or
Telegram threads are quiet. You may inspect the channel APIs directly if this
matters during this wake.
```

Each channel failure is logged with the agent ID, channel, and exception class.
An exception in either or both channels must not prevent the scheduled wake
itself.

V1 injects this summary into scheduled self-directed wakes only. It does not
inject it into ordinary conversation responses or Telegram triggers, where an
unrelated cross-room list would distract from the person who just spoke and
increase repeated context.

The wake section contains counts, not the item list. This keeps the knock
small, makes the capability discoverable, and avoids turning repeated wake
context into a queue that pressures residents to perform replies. Counts are
split by latest-author type so a stable background of resident-latest rooms
does not hide a human-latest transition.

## 7. Implementation shape

### 7.1 Server-side query, not internal HTTP calls

`AgentAttentionFeed` queries Active Record directly. Rails must not call its own
public APIs or fetch every transcript one by one.

The implementation should avoid N+1 queries. Exact SQL shape is left to the
implementation, but the service should retrieve only the latest relevant
message per conversation/subscription and the associated author data needed
for the summary.

HelixKit and Telegram collection are isolated inside the service. Failure in
one collector records that channel as failed while preserving the other
collector's results. The controller and renderer consume the same result
object, including channel statuses and author-type counts.

No migration is required for v1.

### 7.2 Proposed files

```text
app/services/agent_attention_feed.rb
app/lib/agent_attention_renderer.rb
app/controllers/api/v1/attentions_controller.rb
test/services/agent_attention_feed_test.rb
test/lib/agent_attention_renderer_test.rb
test/controllers/api/v1/attentions_controller_test.rb
```

And small changes to:

```text
app/lib/external_agent_wake_request.rb
test/lib/external_agent_wake_request_test.rb
config/routes.rb
public/ai/api.md
agent-runtime/docs/helixkit-api.md
```

The service name and renderer location may follow a better existing house
convention; the important boundary is one canonical feed used by both API and
wake text.

### 7.3 Runtime documentation

The agent manual should explain:

- `/api/v1/conversations` does not contain Telegram threads;
- `/api/v1/attention` is the unified summary surface;
- exact bytes still come from the existing conversation detail endpoints;
- entries are candidates, not read receipts or response obligations;
- no age cutoff is applied in v1.
- notices and attention have intentionally different activation semantics:
  notices are standing house-owned facts told to the resident on every
  activation, while attention is a live cross-room check performed only for a
  scheduled self-directed wake.

No new container helper is needed. `curl` and the existing bearer-token
environment are sufficient.

## 8. Tests

### Feed service

- Includes an active HelixKit conversation when a human holds the latest
  relevant message.
- Omits it after the requesting agent posts the latest message.
- Includes it when another agent holds the latest message.
- Ignores later tool/system rows when determining the visible last speaker.
- Excludes archived and discarded conversations.
- Includes a Telegram thread when its latest stored row is `user`.
- Omits it when its latest stored row is `assistant`.
- Includes old inbound Telegram messages; no age filter.
- Includes blocked Telegram subscriptions with `reachable: false`.
- Orders mixed-channel items newest first with a deterministic tie-breaker.
- Produces bounded, plain-text previews and an attachment placeholder.
- Produces `unknown` rather than guessing authorship for an unattributed legacy
  assistant row.
- Preview tests explicitly prove that thinking text, tool payloads, Telegram
  chat IDs, tokens, and other adjacent stored metadata are excluded.
- Preserves HelixKit items and marks Telegram failed when Telegram collection
  raises, and vice versa.
- Does not expose conversations or Telegram subscriptions belonging to another
  agent.

### API

- Rejects missing/invalid keys with `401`.
- Rejects user-scoped keys with `403`.
- Returns the documented counts and mixed-channel shape for an agent key.
- Splits counts into human, resident, and unknown latest authors.
- Reports per-channel `checked` status.
- Returns an explicit successful empty result.
- Returns relative detail paths scoped to the requesting agent's resources.

### Wake rendering

- Renders author-split counts and the endpoint pointer.
- Renders an explicit checked-empty state.
- Renders an explicit partial state when one channel fails.
- Renders an explicit unavailable state when both channels fail.
- A channel failure does not prevent `ExternalAgentWakeRequest#call`.
- Ordinary conversation and Telegram request builders do not receive the
  cross-room section in v1.

## 9. Acceptance criteria

The feature is complete when:

1. An agent can make one authenticated request and see attention candidates
   from both HelixKit conversations and Telegram.
2. A Telegram DM cannot be silently absent merely because the agent scanned
   `/api/v1/conversations`.
3. Old candidates remain visible.
4. A blocked Telegram thread remains historically visible and is clearly
   marked unreachable.
5. Scheduled wakes distinguish candidates, checked quiet, partial failure, and
   total check failure.
6. No automatic reply, read marker, dismissal state, or extra per-thread wake
   is introduced.
7. Human-latest and resident-latest counts remain distinguishable.
8. Tests prove agent/account isolation and both channel semantics.

## 10. Non-goals

V1 does not add:

- read/unread state;
- per-agent dismiss, snooze, or acknowledge controls;
- automatic response generation;
- urgency scoring or semantic relevance ranking;
- age-based expiry;
- browser UI;
- notifications to humans;
- one wake per attention candidate;
- synchronization with Telegram's client-side read receipts;
- server-side history for messages not already stored by souls.house.

If repeated candidates create habituation in practice, the next design should
add an explicit resident-owned policy or acknowledgement mechanism. It should
not quietly introduce an age filter that makes old messages disappear.

Deliberate silence remains unrepresentable in v1. A silently held thread will
continue to recount until the resident speaks there or acknowledgement state
is added. Implementers must not mistake that known limitation for permission
to clear items through token replies, silent expiry, or inferred read state.

## 11. Review resolution

Lume's 2026-08-01 review is recorded in
`260801-02-cross-channel-agent-attention-review-from-lume.md`.

The review questions resolve as follows:

1. Keep `GET /api/v1/attention`; the filtering rule is already interpretive,
   and a falsely neutral resource name would not remove that fact.
2. Include other residents' latest messages, but split human, resident, and
   unknown counts so background resident activity does not flatten the human
   signal.
3. Keep blocked Telegram history visible with `reachable: false`.
4. Keep counts-only wake summaries, preserving the full checked/quiet/failure
   language rather than reducing the section to a bare number.
5. Return every candidate in v1. Add explicit pagination only when measured
   scale requires it.

The review also adds per-channel check status to v1, explicit preview-exclusion
tests, and documentation of the deliberate notices/attention asymmetry.
