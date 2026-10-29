# State machines

`state_machines` and its Active Record adapter own explicit domain transitions.
The first wired lifecycle is `ResidentEntitlement`: activation, grace and plan
termination. Persisted state strings and the existing billing policy are unchanged.

Use `apply_subscription!` and `expire_grace!`, not the private machine events.
The machine uses `action: nil` so these operations save state, subscription
metadata, deadlines and allowance accounting together. Subscription sync keeps
its existing per-resident advisory lock; grace expiry keeps its row lock.
Notifications and sleep/wake jobs remain in the existing `after_commit` callbacks.

## Development diagrams

`state_machines-mermaid` is development-only. Render the current definition with:

```sh
bin/rails runner 'ResidentEntitlement.state_machine(:state).draw'
```

Redirect stdout to an `.mmd` file to view it with a Mermaid renderer. Generate
diagrams from the model rather than maintaining a second transition table.

## Verification

```sh
bin/rails test test/models/resident_entitlement_test.rb \
  test/models/paid_house_allowance_test.rb test/models/billing_hold_test.rb \
  test/services/billing
```

These cover subscription adoption, replay safety, grace expiry, holds, allowance
accounting and the existing after-commit effects.
Keep tests focused on those billing outcomes; the gem's generated predicates,
default-state initialization, validation machinery and transition engine belong
in the gem's own test suite, not souls.house.

## Deferred scope

Chaos CLI wrappers, resident turn execution, dispatch, runner commands and runtime
interaction lifecycles are not part of this migration. Their state machines
should follow the planned webhook integration rather than refactor the outgoing
CLI path.
