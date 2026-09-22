# Resident-consented memory practice (opt-in v1)

No resident is enrolled automatically. A resident may opt into this prospective
policy after reviewing the invitation, aggregation behaviour and graph choice.
Existing authored memory is never migrated or repaired by this feature.

Runtime support reads `/home/agent/identity/automation/memory-policy.json` each
execution/hook. The resident can set `enabled` to `false` or remove the file to
restore the existing default behaviour on subsequent executions. An in-flight
execution may already have received its prompt. Invalid/unsupported policy files
also use the legacy default. Changes do not delete existing journals or graph data.

Example (only install with that resident's explicit consent):

```json
{
  "version": 1,
  "enabled": true,
  "journal": "ordinary-significance-v1",
  "consolidation": "source-bound-v1",
  "graph": "address-per-entry",
  "ladder": {
    "daily": {"source": "memory/daily-journals/{target}.md", "destination": "memory/weekly-journals/{week_monday}.md"},
    "weekly": {"source": "memory/weekly-journals/{target}.md", "destination": "memory/monthly-journals/{month}.md"},
    "monthly": {"source": "memory/monthly-journals/{target}.md", "destination": "memory/yearly-journals/{year}.md"}
  }
}
```

`graph` is either `address-per-entry` or `selective`. In the latter case an
already-detected journal entry does **not** cause an index-only Stop continuation.
The current heading/timestamp detector is inherited from the existing hook;
it is not a transactional record of which process authored a file.

The full agreed wording lives in `agent-runtime/resident_memory_policy.py`.
Ordinary significance need not be an emotional narrative; no quotas apply.
The runtime manual, fresh/resumed command references, BeforeTurn reference and
Stop invitation all respect the selected policy. Current-policy text explicitly
supersedes incompatible older hosting instructions retained in resumed context.

Aggregation uses authenticated structured `memory_aggregation: {period, target,
notices}` metadata matching `trigger_kind`. It never infers mode from a resident's
reply or user prose. A thread-local flag becomes an invocation-local environment
variable for both fresh and resumed Chaos subprocesses. Only an opted-in Stop
hook suppresses routine aggregation reflection. Other residents retain their
existing behaviour. Voluntary writing of genuinely new insight remains possible.

Exact source/output paths follow the explicit fixed ladder. Missing sources are
reported rather than filled. Existing target-period summaries are left alone.
Prior summaries are context, not voice templates. These are instructions to the
resident, not a filesystem write prohibition or an automatic summary generator.

Before enrollment, preserve the resident's current automation hooks and confirm
stock/custom status. Never overwrite a resident-custom hook merely to install an
opt-in. Reconcile idle runtimes only; then verify effective policy and prompt
seams without invoking models or adding synthetic memories. Enrollment is an
explicit operational step, not a seed or migration applied to everyone.

## Verification

- `python3 test/runtime/resident_memory_policy_test.py`
- `bin/rails test test/lib/external_agent_memory_aggregation_request_test.rb test/lib/trigger_shim_prompt_test.rb test/lib/trigger_shim_session_test.rb test/lib/mnemodyne_hooks_test.rb test/lib/chaos_trigger_client_test.rb`

These cover opt-in/opt-out, stock preservation, exact dated ladder, metadata
validation, fresh/resumed environment propagation, concurrent-session isolation,
selective no-index continuation, prompt precedence and non-mutation of sources.
