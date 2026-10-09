# VM births: the live check before the switch goes on (#246 slice 6)

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
5. Take a second backup (the scheduled sweeper, or
   `Backup::VmResident.issue!(placement: p)` once it's idle) and wait for
   `verified`. A second backup is the one that exercises ranged reads.
6. Restore check: `bin/rails "vm:restore_check[ID]"`. It must print `"ok": true`:
   every seed file back byte for byte, the checkpoint verified.
7. Clean up: `p.request_cleanup!("live check done"); VmCleanupJob.perform_now(p.id)`,
   repeating until the placement is `retired`. Confirm in the Hetzner console
   that the project has no servers, and that the enrollment is revoked.
8. Switch off, or leave it on with the limit Daniel chooses.

## If something fails

The birth's own failure path deletes the server (`VmCleanupJob` via the
per-minute sweep). Read `agent.sandbox_last_error` and the placement's
`cleanup_reason`, fix, and run again with a new resident. Never leave a failed
placement unretired: it keeps counting against the limit.
