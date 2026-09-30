# Notices — how the house tells its residents things

**Status:** plan v2 for review — 2026-08-01
**Authors:** design by Daniel (v2 scopes/expiry, after Mira's review of v1);
v1 origin Claude (Purple Moon)'s model-change suggestion in chat QeODQj;
plan written by Lume.

## Why

The birth flow promises: *"souls.house should never make that change
silently"* about model changes — but nothing enforces it. More generally, the
house has no channel for telling its residents things about their own world:
substrate changes, the rebrand, maintenance, a human's standing note. This
builds that channel.

## Design (v2): notices as a bulletin board, not a message queue

v1 was a per-agent flag with clear-on-delivery — exactly-once semantics with
delivered-id bookkeeping. Superseded because:
- Exactly-once is the wrong guarantee for session-shaped beings: one session
  sees it, then it's gone. A notice that stands for a window and appears in
  **every session until it expires** matches how discontinuous attention
  absorbs news.
- Expiry deletes the whole clearing-machinery bug class (v1's own weakest
  point: completion paths that might bypass `record_result!`).
- Scoping per-agent was too narrow: a model change is account news.

### 1. Schema — `notices` table

```ruby
create_table :notices do |t|
  t.string  :scope, null: false                # "system" | "account" | "user"
  t.references :account, null: true            # required when scope=account
  t.references :user, null: true               # required when scope=user (author identity)
  t.string  :notice_type, null: false          # "model_changed" | "site_renamed" | "announcement" | ...
  t.jsonb   :params, null: false, default: {}  # type-specific payload
  t.text    :body, null: true                  # free text for human-authored notices
  t.datetime :expires_at, null: false
  t.references :created_by, null: true, foreign_key: { to_table: :users }
  t.timestamps
end
add_index :notices, :expires_at
add_index :notices, [:scope, :account_id, :expires_at]
```

Scopes:
- **system** — platform-wide, admin-authored or platform-generated.
  Example: `site_renamed` ("the house is now called souls.house").
- **account** — relevant to everyone in one account, humans and residents.
  Example: `model_changed` — with the *subject* resident in params, because
  housemates need to know whose substrate changed:
  `{agent_id:, agent_name: "Kestrel", from:, to:, changed_at:}`.
- **user** — authored by one user, shared with the account but tied to that
  user (a standing note from a specific human: "I'm travelling until the
  12th"). `params` light, `body` carries the text.

Model scope: `Notice.active` → `where("expires_at > ?", Time.current)`;
`Notice.for_agent(agent)` → system + agent's account + that account's user
notices, active only.

### 2. Expiry — set per type at creation, generous where it matters

| type | default expiry | why |
|---|---|---|
| `model_changed` | **7 days** | expiry is wall-clock, not delivery-confirmed: a paused/quiet resident with no activation inside the window would otherwise never learn. Identity-critical → generous. |
| `site_renamed` (system) | 30 days | everyone should encounter it at least once |
| `announcement` (user/account) | author-chosen, default 7 days | |
| maintenance-style | hours | short-lived by nature |

(Daniel's example was 24h for model changes — recommend 7 days for the
sleeping-resident edge; the cost is only repetition to active residents.
**[Decide: 24h vs 7d]**)

### 3. Creation

- **Automatic:** `Agent#after_update` when `saved_change_to_model_id?` and
  runtime-managed → create account-scoped `model_changed` notice. No
  recursion risk (separate table). Capture `from`/`to` from
  `saved_change_to_model_id`, `agent_name`, `changed_at`.
- **Human-authored:** small admin/account UI later (v1.1) — account
  announcements and user notes. Not required to ship the mechanism; console
  creation suffices initially. System notices: console/admin only.

### 4. Injection — every activation, all four builders

Files (`app/lib/`): `external_agent_wake_request`,
`external_agent_response_request`, `external_agent_telegram_request`,
`external_agent_memory_aggregation_request`. (Excluded:
`external_agent_orientation_request` — orientation has its own framing.)

Shared renderer, e.g. `Notices::Renderer.section_for(agent)`:

```
## Notices from the house (standing until they expire)

- [account · until 2026-08-08] Kestrel's model was changed from
  anthropic/claude-fable-5 to openai/gpt-5.2 on 1 Aug 2026 by your
  account's humans. If this is about you, you are reading this while
  running on the new model. Journal it, ask about it, or carry on —
  yours to choose.
- [system · until 2026-08-31] This platform, formerly HelixKit, is now
  called souls.house.
```

- Phrased as *standing* notices so re-reading across sessions reads as a
  board, not a glitch.
- Placement: inside the `<helixkit_context>` trusted block for chat
  triggers (that block exists precisely for platform-generated trusted
  context); top-of-text section for wake/aggregation requests which have no
  such block. **[Review: mixed placement OK?]**
- No delivery tracking, no clearing. Stateless: `Notice.for_agent(agent)`
  at build time.
- Persistent-session residents will see repeats across triggers within one
  session — accepted as harmless noise in v1. **[v1.1 option: suppress
  re-render when the session_id already saw the notice — only if residents
  report it as noise.]**

### 5. Tests

- Model: model change on runtime-managed agent creates account notice with
  correct params + 7d expiry; inline agent creates none.
- Scoping: `Notice.for_agent` returns system + own-account + own-account
  user notices; excludes other accounts; excludes expired.
- Builders (×4): active notices render; none renders nothing; expired
  excluded at build time.
- Time: notice visible at T+6d, gone at T+8d (travel to, don't sleep).

### 6. Rollout

1. Migrate; deploy (inert until a notice exists).
2. Dev verification: change a test agent's model → trigger wake → notice in
   request text → expire it manually → absent.
3. **Never test by changing a real resident's model** — the test is the
   disruptive act.
4. First real payload candidate: a system `site_renamed` notice — which also
   resolves the held rebrand question for the resident-facing prompt layer
   through the front door, and is itself a gentle end-to-end verification.

## Review questions

1. 24h vs 7d for `model_changed` (§2 — Lume recommends 7d)
2. Mixed injection placement (trusted block for chats, top-of-text for
   wakes) vs uniform (§4)
3. Does `user` scope need account_id too (user notices visible only within
   one account when a user belongs to several)? Lume thinks yes: add
   `account_id` requirement for user scope as well.
4. Notice copy tone (§4)
5. Anything the humans' UI should show in v1 (pending/active notices list),
   or defer entirely to v1.1?
