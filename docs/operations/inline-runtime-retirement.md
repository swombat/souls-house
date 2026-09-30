# Legacy inline-runtime retirement

This operator procedure is retained for installations that still contain inline
rows. It is not ordinary setup, an automatic cleanup or a deployment attestation.
It requires explicit operator approval, a fresh inventory and verified backups.
The task is implemented in `lib/tasks/agent_deprecation.rake`; inspect it before use.

Extracted from the [2026-09-05 rollout record](../.bak/plans/260905-01b-rubyllm-removal-implementation-checkpoint.md).
The historical verification counts and one-checkout deployment status do not carry
forward as guarantees about another installation. Current availability rules are
in [resident runtime](../resident-runtime.md).

## Transition and rollback gates

1. Record the tested release commit and take the normal verified backup.
   Inventory production legacy/migrating/provisioning states and contradictory
   harness metadata. Resolve in-flight migrations/provisioning explicitly;
   do not wake, copy or replace a resident as a side effect.
2. Deploy the applicable additive migration and a tested compatible release. The extraction
   binary itself handles legacy rows and old queued job names; a partially
   removed intermediate binary is unnecessary. Restart **every web, job and
   scheduler process** and verify that no old inline executor remains before
   changing runtime data. Record that tested release as the rollback floor.
3. Obtain a fresh read-only inventory; it contains flags, not secret values:

   ```sh
   bin/rails agents:deprecation_inventory
   ```

4. After explicit operator approval, submit the reviewed numeric database IDs:

   ```sh
   CONFIRM=deprecate-inline REVIEWED_IDS=123,456 bin/rails agents:deprecate_inline
   ```

   The transaction locks the candidate rows and requires the complete inline
   candidate set. It rejects unresolved migrating rows, missing IDs, supported
   runtimes and candidate harness metadata. It stamps runtime/reason/time and
   clears trigger tokens. Repeating the same reviewed list is safe; an empty
   list never means “all agents.”
5. Verify retired scoped credentials, announce and dispatch fail closed;
   current harness residents, owner credentials, history, downloads and utility
   inference must continue to work. Do not invoke test wakes against real
   residents merely to validate deployment.
6. Keep historical columns and no-op queue shells in this release. Once this
   release is installed, roll back only to a compatible tested binary—not an
   old inline executor. Rollback must never reactivate retired agents or restore
   cleared trigger tokens. Remove queue shells only in a later release after
   explicitly verifying old queues are drained.

### Reconciling stale harness metadata before transition

Old cancelled migrations can leave `container_name` or `endpoint_url` on an
inline row. The transition deliberately refuses these rows rather than guessing.

1. From a fresh inventory and verified backup, record each specific ID and its
   current runtime/metadata for operator review. Do not paste credentials into
   tickets or logs. Unresolved `migrating` rows require separate investigation.
2. On the row's **actual sandbox host**, confirm there is no running **or stopped**
   container for that identity. An empty local Docker listing is not evidence
   about a remote host. Check endpoint ownership and migration history too.
   An existing container, unreachable host, actual birth, or ambiguous ownership
   means stop and investigate—not remove resources or clear metadata.
3. Only for a confirmed cancelled, never-born inline migration with no harness,
   an operator may clear the specifically reviewed stale pointer fields in a
   console on the intended environment. Recheck under a row lock:

   ```ruby
   agent = Agent.find(REVIEWED_ID)
   agent.with_lock do
     raise "Not an uncommitted inline migration" unless agent.runtime == "inline" &&
       agent.birth_committed_at.nil? && agent.outbound_api_key_id.nil?
     # First compare these pointer values with the operator's reviewed snapshot.
     # Abort if either changed since the host/endpoint checks.
     raise "Metadata changed" unless agent.container_name == REVIEWED_CONTAINER_NAME &&
       agent.endpoint_url == REVIEWED_ENDPOINT_URL
     agent.update_columns(container_name: nil, endpoint_url: nil)
   end
   ```

   Never clear a birth timestamp to force eligibility. An outbound credential
   association requires its own ownership/revocation review; this procedure
   refuses it. Preserve volumes, identity files, GitHub references and history.
4. Rerun the inventory and approve the complete ID set again before invoking
   the transition task. No automatic stale-metadata cleanup flag is provided.
