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
# fresh pause claim (Backup::PauseClaim, written just before `docker pause`
# and released after the unpause). Until 21 Nov 2026 these were left out,
# on the reasoning that the nightly run picks them up again after a
# restart. It does pick the backup up, but a restart between pause and
# unpause leaves the resident paused: deploy d11e730b at 04:12:30Z stopped
# the worker holding Mira's pause, and she stayed frozen until 06:50.
# A claim older than pause_claim_fresh is not listed. A house backup
# pauses for minutes, so an old claim belongs to a worker that is already
# gone, and waiting for it would only hold the deploy up.
require "json"

pause_claim_fresh = 30 * 60 # seconds

now = Time.current
thinning = Agent.where.not(backup_thinning_started_at: nil)
                .select { |agent| Backup::VmThinning.running?(agent, now:) }.map(&:id)
on_vms = VmBackup.where(state: "pending").where("deadline_at > ?", now).distinct.pluck(:agent_id)
pausing = Backup::PauseClaim.where("created_at > ?", now - pause_claim_fresh).distinct.pluck(:agent_id)
puts({ thinning: thinning.sort, backing_up: (on_vms | pausing).sort }.to_json)
