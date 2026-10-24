# Home roster and account cost markers (#422)

Backend contract; consuming costs/glossary UI and lazy HTTP props are separate
integration work. Scoped HTTP reports remain authoritative. No pricing,
estimated/unestimated, day-limit, membership or administrator policy changes.

* `HomeResidentRoster:<account>` carries only `{"action":"refresh"}` for Agent
  create, name, active, home-account changes and destroy. The existing Agent
  presentation hook snapshots old/new home IDs on save and the current home on
  destroy. Guest edges are not targets. Health/runtime/presentation bookkeeping
  stays quiet. This is the shared union approved in comment 6218165517.
* `AccountCostActivity:<account>` carries the same content-free marker for actual
  `finished_at` or usage-field changes. The explicit field constant includes
  `telemetry_schema_version`, since `local_usage?` requires that version even
  when tokens and scope did not change. Home is read from the persisted Agent;
  a stale loaded association or a guest conversation cannot redirect costs.
* Both streams reuse SyncChannel's Account authorization: confirmed access or
  existing site-admin access, never `all`, collections, native or anonymous.
  Neither marker contains resident IDs, costs, output or credentials.

## Commit/coalescing boundary

Roster hints capture IDs at the write and wait for all transactions to commit.
Cost hints accumulate unique account IDs on the public current transaction
object and register one after-commit callback. Multiple interactions/writes for
one account in that transaction emit once; a later touch cannot erase a prior
change. Rollback discards the callback and its transaction-owned state.
Savepoints own independent sets, so their rollback cannot contaminate a parent.
Committed savepoint callbacks transfer to the parent and wait for the outer
commit, but a parent and committed child that both change costs can emit two
hints. This is **not** cross-savepoint deduplication or a timed/cross-transaction
debounce. No job, cache lock, schema change or new durable delivery guarantee.
As with existing invalidations, a failed broadcast after commit is not a DB
rollback; initial/reconnect HTTP catch-up is the consumer's responsibility.

## Actual writer and bypass audit

Audited application/lib Ruby writers on base `bfaa47f9`:

* `AgentRuntimeInteraction.record_trigger!` calls `record_result!`, which writes
  usage and `finished_at` together via `update!`; the queued 202 path only changes
  transport. `ExternalAgentResponseRequest#perform` likewise reaches
  `record_result!` under the interaction lock. No claim that every late result
  was previously missed.
* `RuntimeActivityIngestion#call` applies supervisor termination and then calls
  `record_result!(from_callback: true)` in the run lock transaction. Those two
  terminal writes coalesce. Heartbeats/detail/replays do not write cost fields.
  Its existing transport-status guard can reject duplicate terminal accounting;
  this producer deliberately does not change which telemetry gets persisted.
* `ResidentTurn#finish!` calls `record_result!` in nested locks. Repeated finish
  returns early. `resolve_after_containment!` reaches that same path; cancellation
  preserves already received accounting without another interaction write.
* Legacy `record_error!`, live `finish_execution!` and deadline reconciliation
  use `update!` for actual completion. A pending durable turn's acknowledgement
  error is not completion. Post-completion usage-only saves now notify even
  without another `finished_at` change.
* Application interaction `update_columns`/`update_all` writers found are
  FollowThroughCheckJob's `follow_through_checked_at` and
  RunFailureNoticeJob's `failure_notice_message_id` bookkeeping: quiet.
  Tests exercise the actual jobs, including the follow-through unique-conflict
  `update_all` fallback and the failure notice's system-message write.
  No production callback-bypassing terminal/usage or Agent home-account writer
  was found. Future direct SQL/bulk writes must explicitly call the helper;
  callbacks cannot observe arbitrary SQL or console edits.
* Agent portability activation uses `update_columns(active: ...)`. Its narrow
  explicit hint compares pre/post effective active state inside the lock:
  success notifies after commit, failed activation returning to inactive stays
  quiet, including unknown-exit health bookkeeping. Stop/export use normal
  active saves. Portability import bypasses runtime/identity fields only.
  Admin bulk follow-through changes, AgentJournalStatsJob's refresh lease and
  test fixture runtime/model bypasses do not match the shared roster union.

Focused tests use actual local records/SQL/transactions and local stubbed
runtime clients, not a vendor. Rails-only rollback is the previous revision;
there is no migration. Browser/reconnect/draft evidence belongs to integration,
not these backend tests.

## Local recovery verification (2026-10-17)

The recovered 43-test producer suite passed before additional coverage. The final
combined producer/terminal-writer/channel/presentation/pricing regression ran
266 tests and 1,445 assertions: zero failures, errors or skips, in 71.3 seconds.
It used the credential-allowlisted test wrapper and normal checkout ownership
lock. All 10 changed Ruby files pass RuboCop with a temporary Ruby 3.4
`parser_whitequark` target; the repository's stock Ruby 4.0 parser remains
unsupported by the pinned RuboCop toolchain. No repository lint setting changed.
The pre-existing missing-assertion warning in
`RuntimeActivityIngestionTest#test_ordinary_activity_reads_do_not_acquire_a_write_lock`
remains outside this producer work.
