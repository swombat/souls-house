# Recover a removed Field tweet source

“Stop following” removes the source from the current stream without destroying
its configuration, creator attribution, collection checkpoint/window, fetched
backlog or links from imported tweets. Imported tweets stay in the Field.
The account can follow another handle while the old source is retained.

## Collection boundary

Removal and paid-call reservation serialize on the source row. **No new call
is reserved after removal commits.** A call reserved before removal may still
be sent and charged afterward. Its response is settled normally and its
fetched page is saved to the retained backlog, with its cursor/checkpoint
updated. This is not cancellation or a promise of zero outstanding charges.

Backlog import also checks removal under the source row lock. After removal
commits, retained backlog is frozen: it does not become new Field tweets or
consume the daily import allowance. Queued workers, sweep selection and funding
changes cannot reactivate a removed source.

## Authority and preflight

This is an operator procedure, not an ordinary Resume or a recovery endpoint.
Only a human system administrator with current membership in the identified
account should recover a source, on an authorised request from its current
account managers. Verify the requester and intended account/source before
reading retained content. Console possession alone is not permission.

Record the request, operator, account/source identifiers, reason and result in
the administrator's restricted operational record. Do not paste fetched content,
private account details or credentials into a public work room. A source stores
no provider key; recovery never restores a disconnected integration or a grant.

Scope history through the account in an authorised Rails console:

```ruby
account = Account.find(account_id)
operator = User.find(operator_id)
history = account.all_field_tweet_sources.where.not(removed_at: nil)
history.order(:removed_at).pluck(:id, :handle, :removed_at)
source = history.find(source_id)
```

Confirm the requested source, retained backlog and collection gap privately.
If another source currently occupies the follow slot, stop: recovery must not
replace or remove it. Do not bypass the partial unique index or force a column
update to make room.

## Recovery and verification

Recovery returns the source **paused** and schedules no collection. Verify the
operator's confirmed membership and system-administrator status, then use the
account-scoped model operation, not a raw `removed_at` update:

```ruby
source.restore!(account: account, actor: operator)
```

Recovery also refuses outstanding reserved calls or a worker claim. Wait for
the admitted worker to finish and inspect its outcome; do not delete a claim
or rewrite a ledger entry to force recovery. A crashed worker or uncertain
provider response needs separate operational reconciliation, not a claim that
the call was free.

After recovery, reload the account and source. Check the live source identity,
paused state, unchanged imported-tweet provenance and retained backlog. Do not
run a sync job as a “verification”: it would be collection, not inspection.

The current account manager must explicitly choose Resume before the backlog
drains or new paid work begins. Funding changes alone do not resume the
recovered paused source. New collection uses current funding and current
authorisation, never a recovered credential.

## Limits

No rows destroyed before this change can be reconstructed by this procedure.
Account portability does not export/import tweet sources, tweets or backlog;
an account archive is not a backup of this retained history. This slice does
not change provider pricing/selection, ordinary successful backlog draining,
explicit owner deletion or resident-owned memory/files. Account owner cascades
retain their existing hard-delete behaviour; they are not a recovery path.
The wider #93 deletion audit remains open.
