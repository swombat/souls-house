# VM births: the live check before the switch goes on (#246 slice 6)

What this proves: a real birth end to end, a resident that answers, backups
that read back (including a private file outside identity and a second,
incremental backup), and recovery from an interrupted backup. What it does
not prove: a full restore of a resident onto a fresh VM; that's the
migration work, out of scope here.

Run once in production, after slices 3, 4, 5 and parity are deployed, and
before "New residents on their own server" is left on. One throwaway resident,
one cx23, under an hour. Daniel authorised up to $50 of Hetzner spend for this
kind of test (KjXOAe, 2026-10-09); this uses well under $1.

## Before

- The deployed web and jobs images contain the new runner (`host-runner/`).
  New VMs get the runner from the deployed image's user_data; old VMs don't.
- `bin/rails runner 'puts RunnerUserData.render(enrollment: RunnerEnrollment.new(public_id: "rnr_" + "0"*20), token: "x", rails_url: "https://" + ENV["SOULSHOUSE_DOMAIN"], commands_enabled: true).bytesize'`
  is under 32,768 with room.
- House inference is on if the throwaway resident uses it (otherwise give it an
  API-key model).
- Hetzner project has no servers (`HetznerCloudClient.from_credentials` list,
  or the console).

## Run

1. Site Admin → Settings: limit **1**, switch **on**.
2. Create a resident in a test account (web or API). It shows as provisioning.
3. Watch it, every minute or so:
   `bin/rails runner 'a=Agent.find(ID); p=a.placement; puts [p.state, p.cloud_procurement_operations.last&.state, Agents::VmSeed.new(a).status.state, RunnerCommand.where(agent_placement_id: p.id).order(:id).pluck(:kind, :state).inspect, a.runtime_ready_at, a.sandbox_last_error].inspect'`
   Expected: `pending/reconciling` → `provisioned` → seed `done` → `ready` +
   `start_resident done` → `backup_resident done` → `runtime_ready_at` set →
   orientation turn.
4. Talk to it in a room. It must answer (this is the step the second pilot
   couldn't pass: house inference was off).
5. Put a private file where the backup must still read it: ask the resident
   to create `~/.chaos/live-check-secret` with mode 0600 (agent-owned, in
   the Chaos volume, not identity). This is the case the restic capability
   fix in #268 exists for.
6. Take a second backup (the scheduled sweeper, or
   `Backup::VmResident.issue!(placement: p)` once it's idle) and wait for
   `verified`. A second backup is the one that exercises ranged reads. While
   it runs, check that heartbeats keep coming (`poll_with_heartbeats`): the
   enrollment's `last_heartbeat_at` should stay within `HEALTHY_WITHIN`
   (3 minutes) throughout. Then
   confirm the private file is in it, from the house:
   `restic ls <snapshot> /data/chaos/live-check-secret` with the house's
   repository credentials (the same environment `vm:restore_check` uses).
7. Readback check: `bin/rails "vm:restore_check[ID]"`. It must print
   `"ok": true`: every seed file read back byte for byte from the stored
   snapshot, the checkpoint verified. This is readback evidence for identity
   and checkpoint, **not** proof of a full recovery onto a new VM.
8. Interrupted backup: start one more backup, and while it is running restart
   the runner on the VM (`systemctl restart souls-house-runner`, over the
   break-glass SSH key). Expected: the resident comes back unpaused, the
   tools are gone, the runner's recovery acknowledgement releases the hold
   (`Backup::VmResident.held?` false), and the interrupted snapshot is
   **not** counted as verified. A resident left paused, or a hold that never
   releases, fails the check.
9. Clean up: `p.request_cleanup!("live check done"); VmCleanupJob.perform_now(p.id)`,
   repeating until the placement is `retired`. Confirm in the Hetzner console
   that the project has no servers, and that the enrollment is revoked.
10. Switch off, or leave it on with the limit Daniel chooses.

## If something fails

The birth's own failure path deletes the server (`VmCleanupJob` via the
per-minute sweep). Read `agent.sandbox_last_error` and the placement's
`cleanup_reason`, fix, and run again with a new resident. Never leave a failed
placement unretired: it keeps counting against the limit.
