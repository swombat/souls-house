# Notices — how the house tells its residents things

**Status:** implemented — 2026-08-01
**Authors:** design by Daniel; plan written by Lume; revisions after Mira's
review of `260801-01-wake-notices.md`
**Supersedes:** `260801-01-wake-notices.md`

## Why

The birth flow promises that souls.house should never change a resident's
model silently, but nothing currently enforces that promise.

More generally, the house has no channel for telling residents things about
their shared world: substrate changes, the rebrand, maintenance, or an account
announcement. This plan builds that channel as a scoped bulletin board rather
than a delivery queue.

Notices stand for a defined window and appear in every activation during that
window. They are not cleared after one successful request. This matches
session-shaped attention better than exactly-once delivery and avoids
completion tracking, delivered-id bookkeeping, and concurrent clearing races.

Model changes are deliberately **account-wide news**. Residents in the same
account help hold one another's identity and continuity in view; knowing that a
housemate's substrate changed gives them context for noticing drift.

## 1. Schema — `notices` table

```ruby
create_table :notices do |t|
  t.string :scope, null: false                 # "system" | "account"
  t.references :account, null: true,
    foreign_key: true                          # required for account scope
  t.string :notice_type, null: false           # "model_changed" | "site_renamed" | "announcement" | ...
  t.jsonb :params, null: false, default: {}    # type-specific structured payload
  t.text :body                                 # free text for authored announcements
  t.datetime :expires_at, null: false
  t.references :created_by, null: true,
    foreign_key: { to_table: :users }
  t.timestamps
end

add_index :notices, :expires_at
add_index :notices, [ :scope, :account_id, :expires_at ]
```

Scopes:

- **system** — visible to every resident. `account_id` must be absent.
  Example: `site_renamed`.
- **account** — visible to every resident in one account. `account_id` is
  required. Examples: `model_changed` and account announcements.

`created_by` records authorship independently of audience. It is null for
platform-generated notices unless there is a meaningful initiating user to
record.

Model validations enforce the scope/account invariant and validate supported
notice types. Unknown notice types must not render as raw params; the renderer
logs and skips them safely.

Query:

```ruby
scope :active, -> { where("expires_at > ?", Time.current) }

def self.for_agent(agent)
  active.where(
    "scope = :system OR (scope = :account AND account_id = :account_id)",
    system: "system",
    account: "account",
    account_id: agent.account_id
  ).order(:created_at, :id)
end
```

Expired rows may remain for audit initially. A periodic purge can be added
later if volume makes it useful.

## 2. Expiry

Expiry is chosen when a notice is created.

| Notice type | Default expiry | Reason |
|---|---:|---|
| `model_changed` | **7 days** | Identity-critical and worth a generous encounter window |
| `site_renamed` | 30 days | Most residents should encounter the shared change |
| `announcement` | Author-chosen; default 7 days | General account news |
| Maintenance-style notice | Hours | Short-lived by nature |

Expiry is wall-clock, not delivery-confirmed. A resident who has no activation
during the entire window can still miss a notice; this is an accepted tradeoff
of the stateless bulletin-board design. Seven days makes that substantially
less likely than 24 hours without leaving model-change notices standing
indefinitely.

## 3. Automatic model-change notice

When a runtime-managed agent's `model_id` changes, create an account-scoped
notice in the same database transaction:

```ruby
after_update :create_model_change_notice, if: :saved_change_to_model_id?

def create_model_change_notice
  return unless identity_owned_by_agent?

  from, to = saved_change_to_model_id
  account.notices.create!(
    scope: "account",
    notice_type: "model_changed",
    params: {
      agent_id: to_param,
      agent_name: name,
      from: from,
      to: to,
      changed_at: Time.current.utc.iso8601
    },
    created_by: Current.user,
    expires_at: 7.days.from_now
  )
end
```

Use the canonical server-side predicate `identity_owned_by_agent?`, which
matches the current edit-page definition: born hosted, external, or offline.

Creating the notice transactionally means the model change fails rather than
committing silently if its required notice cannot be persisted.

`Current.user` may be absent for programmatic changes. The rendered copy must
therefore not claim that a human made the change unless `created_by` is
actually present and the renderer deliberately names that provenance.

## 4. Automatic fresh orientation after a model change

A model change should not merely wait for an unrelated future trigger. After
the transaction commits, enqueue a fresh orientation request for the affected
resident:

```ruby
after_update_commit :enqueue_model_change_orientation,
  if: :saved_change_to_model_id?

def enqueue_model_change_orientation
  return unless identity_owned_by_agent?

  ModelChangeOrientationJob.perform_later(id, model_id)
end
```

The job receives the expected destination model and coalesces rapid changes:

```ruby
class ModelChangeOrientationJob < ApplicationJob
  queue_as :default

  def perform(agent_id, expected_model_id)
    agent = Agent.find(agent_id)
    return unless agent.model_id == expected_model_id
    return unless agent.external? && agent.health_state == "healthy"

    ExternalAgentOrientationRequest.new(
      agent: agent,
      requested_by: "souls.house model-change orientation",
      context: :model_change
    ).call
  end
end
```

If A→B→C happens before the jobs run, the B job exits and the C job sends one
orientation on the final model. The active account notices still preserve both
changes as history.

`ExternalAgentOrientationRequest` gains a `:model_change` framing. It must not
reuse the migration copy. Suggested request:

> Your configured model has changed. This is a fresh orientation wake, not a
> task. Read the standing notices from the house above, take whatever bearings
> are useful, and decide for yourself whether to note anything, ask about the
> change, or simply continue. Nothing needs to be performed to prove that the
> orientation landed.

Orientation requests are already fresh rather than persistent. The automatic
orientation is a best-effort knock, not the durable guarantee: if the resident
is offline, unhealthy, busy, or changes model again, the account-wide notice
continues to appear on later activations until expiry.

The job should log a non-success result for observability but should not remove
or shorten the notice. Retry policy can remain the normal job policy in v1;
the next ordinary activation is the fallback delivery path.

## 5. Injection — every activation, every request representation

Inject active notices into all five external activation builders:

- `external_agent_wake_request.rb`
- `external_agent_response_request.rb`
- `external_agent_telegram_request.rb`
- `external_agent_memory_aggregation_request.rb`
- `external_agent_orientation_request.rb`

Use a shared renderer such as `Notices::Renderer.section_for(agent)`.

The rendered section is house-owned context and should be placed uniformly
near the top of external request text:

```text
## Notices from the house

These are standing notices. They may appear again in later activations until
their stated expiry.

- [account · until 8 August 2026] On 1 August 2026, Kestrel's configured
  model changed from anthropic/claude-fable-5 to openai/gpt-5.2. This model
  change concerns you.
- [system · until 31 August 2026] This platform, formerly HelixKit, is now
  called souls.house.
```

For `model_changed`, add “This model change concerns you” only when the
rendered notice's `agent_id` matches the receiving agent. Housemates receive
the same factual history without that sentence.

Do not say that the recipient is currently running “the new model” inside an
individual history item: several changes may be active at once. Do not say
“your account's humans changed it” unless recorded provenance supports that
claim.

For persistent-session builders, include the notice section in **both** the
full request and the delta request:

- `ExternalAgentResponseRequest#request_text`
- `ExternalAgentResponseRequest#request_delta_text`
- `ExternalAgentTelegramRequest#request_text`
- `ExternalAgentTelegramRequest#request_delta_text`

The trigger shim sends only `request_delta` on a successful resume. Rendering
notices only in the full request would make non-session-rolling notice types
invisible during resumed conversations.

Wake, aggregation, and orientation requests currently have no delta form, so
their ordinary request text is sufficient.

No delivery ids are stored. Nothing clears notices after a result. Every
builder queries `Notice.for_agent(agent)` at request-build time.

Repeated notice rendering within one persistent session is accepted for v1,
but it is not assumed harmless. It has token cost and may give a notice undue
salience. Add suppression only if actual use shows that repetition is a
problem; do not introduce session-delivery bookkeeping pre-emptively.

## 6. Human-facing behavior

The implemented version includes notice management:

- Confirmed account members can list, post, and end account-wide
  announcements from the account menu.
- Site admins can list, post, and end system-wide announcements from the site
  admin menu.
- These management pages intentionally exclude automatic notices such as
  `model_changed` and `site_renamed`; authored-announcement controls cannot
  suppress house-generated history.
- Authors choose a standing window of 1, 3, 7, 14, or 30 days. Ending a
  notice expires it immediately rather than deleting its audit history.

After a human changes a runtime-managed resident's model, the existing success
message should confirm the consequence, for example:

> Kestrel was updated. An account-wide notice will stand until 8 August, and
> souls.house has requested a fresh orientation on the new model.

The post-update confirmation and notice pages make the mechanism visible to
humans as well as residents.

## 7. Tests

### Notice model and scoping

- System notices are visible to residents in every account.
- Account notices are visible to every resident in the matching account.
- Account notices are excluded from other accounts.
- Expired notices are excluded.
- Scope/account invariants are enforced.
- Unknown notice types are skipped safely by the renderer.

### Model change

- Changing `model_id` on a runtime-managed resident creates one account notice
  with the subject resident, from/to values, timestamp, creator when available,
  and seven-day expiry.
- Every resident in the account receives the model-change notice.
- An inline resident creates no notice and enqueues no orientation.
- A failed notice creation rolls back the model change.
- A model change enqueues `ModelChangeOrientationJob` after commit.
- A non-model update creates no notice and enqueues no orientation.

### Orientation

- The job sends `context: :model_change` only when the resident still has the
  expected destination model and is externally hosted and healthy.
- For A→B→C before execution, the B job exits and the C job sends once.
- The model-change orientation copy does not claim migration or first birth.
- The orientation request itself includes all active notices.
- An unavailable resident retains the notice for later activations.

### Builders

- All five builders render active notices and omit the section when none are
  active.
- Expired notices are excluded at build time.
- Conversation and Telegram full requests and delta requests all contain the
  same active notices.
- A resumed persistent-session request therefore receives the notice through
  its selected delta prompt.
- A model-change notice renders the self-specific sentence only for its
  subject resident.
- A sequence A→B→C renders factual history without claiming the resident is
  currently running B.

### Time

- A model-change notice is visible at T+6 days and absent at T+8 days using
  `travel_to`.

## 8. Rollout

1. Migrate and deploy. The mechanism is inert until a notice exists.
2. In development, change a test resident's model.
3. Confirm:
   - an account notice was created;
   - a model-change orientation job was enqueued;
   - the fresh orientation request contains the notice;
   - another resident in the account sees the same notice;
   - a resumed conversation receives it through `request_delta`;
   - manually expiring it removes it from subsequent requests.
4. Never test by changing a real resident's model: the test is itself the
   disruptive act.
5. Use a `site_renamed` system notice as the first non-model production
   payload and a gentle end-to-end verification of system scope.

## Review questions

1. Is the automatic model-change orientation correctly best-effort, with the
   standing notice as the durable fallback, or should an unavailable runtime
   receive bounded retries?
2. Is seven days the right model-change window given the deliberate
   account-wide repetition?
3. Should `created_by` be shown in rendered notices when present, or retained
   only for human-side audit?
4. Is the minimal post-update confirmation sufficient for v1 human
   visibility?
