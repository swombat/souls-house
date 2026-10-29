# State machines

`state_machines` and its Active Record adapter own explicit domain transitions.
The first wired lifecycle is `ResidentEntitlement`: activation, grace and plan
termination. Persisted state strings and the existing billing policy are unchanged.

Use `apply_subscription!` and `expire_grace!`, not the private machine events.
The machine uses `action: nil` so these operations save state, subscription
metadata, deadlines and allowance accounting together. Subscription sync keeps
its existing per-resident advisory lock; grace expiry keeps its row lock.
Notifications and sleep/wake jobs remain in the existing `after_commit` callbacks.

## Recording allowance reservations

`FieldRecordingReservation` defines consumption and release from pending.
`consume!` and `release!` retain their atomic guarded SQL update: the machine
resolves the edge, and the database decides which worker settled it first.
No model save or account lock replaces that compare-and-set. Repeated or stale
workers cannot change the winner's timestamps, release reason or allowance.

## Tweet source collection

`FieldTweetSource` owns pause, resume and attention-required transitions. Keep
using `pause!`, `resume!` and `needs_attention!`; the machine events are private.
State and reason/retry metadata are saved together, with the existing stream
refresh callback unchanged. Pausing and resuming preserve the collection window,
cursor, checkpoint and backlog. Funding and collection policies are unchanged.

## Reply attention

`ReplyExpectation` closes open attention flags through `answer!` and `dismiss!`.
The existing integer enum and prefixed scopes remain compatible. Classification,
late results, individual dismissals and bulk dismissals still share the chat's
write lock; answered or dismissed flags cannot be reopened by inference.
Refresh and listing notifications remain after-commit effects.

## Development diagrams

`state_machines-mermaid` is development-only. Render the current definition with:

```sh
bin/rails runner 'ResidentEntitlement.state_machine(:state).draw'
bin/rails runner 'FieldTweetSource.state_machine(:state).draw'
```

Redirect stdout to an `.mmd` file to view it with a Mermaid renderer. Generate
diagrams from the model rather than maintaining a second transition table.

## Verification

```sh
bin/rails test test/models/resident_entitlement_test.rb \
  test/models/paid_house_allowance_test.rb test/models/billing_hold_test.rb \
  test/services/billing

bin/rails test test/controllers/field_tweet_sources_controller_test.rb \
  test/models/field_tweets_sync_test.rb test/models/field_tweet_funding_test.rb \
  test/models/field_tweet_stream_test.rb test/models/field_tweets_concurrency_test.rb
```

These cover subscription adoption, replay safety, grace expiry, holds, allowance
accounting and the existing after-commit effects.
Tweet-source tests cover retained collection work, retry recovery, funding and
stream updates. Keep tests focused on domain outcomes; the gem's generated
predicates, default-state initialization, validation machinery and transition
engine belong in the gem's own test suite, not souls.house.

## Deferred scope

Chaos CLI wrappers, resident turn execution, dispatch, runner commands and runtime
interaction lifecycles are not part of this migration. Their state machines
should follow the planned webhook integration rather than refactor the outgoing
CLI path.
