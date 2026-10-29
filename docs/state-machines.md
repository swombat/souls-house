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

## Repository watches

`RepositoryWatch` defines its one-shot fulfilment, expiry, cancellation and
undeliverable paths. Its existing public operations retain their row locks,
single delivery record and after-commit enqueueing. Replayed webhooks and
reconciliation still use the same idempotent fulfilment path. Delivery and
resident-wake execution are unchanged.

## Deploy alarm observations

`DeployAlarmState#record_observation!` records current, stuck and unknown
observations with their metadata in one save. `DeployAlarm` still owns evaluation,
grace periods, recovery and notification deduplication. Repeated observations
and visibility blips preserve an ongoing episode; no notification or deployment
work moved into machine callbacks.

## Cloud purchases

`CloudProcurementOperation` defines submission, uncertain outcomes, discovery,
review, provisioning and verified deletion. `CloudProcurement` applies those
edges under its existing locks and saves evidence with each edge. Provider I/O,
admission checks, enrollment and placement bookkeeping keep their existing
ordering. There is still only one create request; uncertainty cannot release
the purchase reservation, and provisioned does not mean runtime-ready.

## Paid birth orders

`ResidentBirthOrder` defines completion, unpaid abandonment and retryable birth
failure. `Billing::PaidBirth` still checks payment, holds the order lock and
commits the resident with its born order before linking Stripe. Settled orders
clear the draft; failures retain it for retry. Only order bookkeeping changed:
ordinary birth, provisioning and runtime execution remain untouched.

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

bin/rails test test/models/field_recording_reservation_test.rb \
  test/models/reply_expectation_test.rb test/models/direct_reply_attention_test.rb \
  test/controllers/api/v1/reply_attention_test.rb \
  test/controllers/chats/reply_dismissals_controller_test.rb \
  test/jobs/classify_reply_expectations_job_test.rb

bin/rails test test/models/repository_watch_test.rb \
  test/jobs/repository_watch_jobs_test.rb test/jobs/repository_watch_recovery_test.rb \
  test/controllers/accounts/repository_watches_controller_test.rb \
  test/models/deploy_alarm_test.rb test/jobs/deploy_alarm_check_job_test.rb

bin/rails test test/services/cloud_procurement_test.rb \
  test/jobs/provision_vm_agent_job_test.rb
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
