# Run by the deploy (worker.py, wait_for_backups) inside the live web
# container before the release is switched. A release switch stops the job
# worker, and a VM thinning or a VM backup that is running then is cut off:
# the thinning leaves its mark and the resident's backups stay paused until
# the recovery job has taken it over and run it again from the start.
#
# Prints one JSON line: the residents whose thinning holds a fresh mark, and
# those with a backup that is pending and not past its deadline.
#
# A resident backed up on the house is listed while its backup holds a
# pause claim (Backup::PauseClaim, written just before `docker pause`
# and released after the unpause). Until 21 Nov 2026 these were left out,
# on the reasoning that the nightly run picks them up again after a
# restart. It does pick the backup up, but a restart between pause and
# unpause leaves the resident paused: deploy d11e730b at 04:12:30Z stopped
# the worker holding Mira's pause, and she stayed frozen until 06:50.
# Any claim counts, however old (Mira, #1096): a claim is gone only when
# its backup released it after the unpause, or an operator released it by
# the recovery runbook. A claim whose heartbeat (touched_at, every 60 s
# while the backup holds the pause) is older than 3 minutes is also listed
# in stale_claims: most likely a dead worker's, and the deploy defers and
# says so rather than deciding that the pause is safe to cut through.
# While the deploy's fence is up (Backup::DeployFence) no new claim is made.
require "json"

heartbeat_fresh = 3 * 60 # seconds

now = Time.current
thinning = Agent.where.not(backup_thinning_started_at: nil)
                .select { |agent| Backup::VmThinning.running?(agent, now:) }.map(&:id)
on_vms = VmBackup.where(state: "pending").where("deadline_at > ?", now).distinct.pluck(:agent_id)
claims = Backup::PauseClaim.all
pausing = claims.distinct.pluck(:agent_id)
stale = claims.where("COALESCE(touched_at, created_at) <= ?", now - heartbeat_fresh).distinct.pluck(:agent_id)
puts({ thinning: thinning.sort, backing_up: (on_vms | pausing).sort, stale_claims: stale.sort }.to_json)
