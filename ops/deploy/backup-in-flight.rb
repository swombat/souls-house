# Run by the deploy (worker.py, wait_for_backups) inside the live web
# container before the release is switched. A release switch stops the job
# worker, and a VM thinning or a VM backup that is running then is cut off:
# the thinning leaves its mark and the resident's backups stay paused until
# the recovery job has taken it over and run it again from the start.
#
# Prints one JSON line: the residents whose thinning holds a fresh mark, and
# those with a backup that is pending and not past its deadline. Residents
# who back up on the house are not listed: the nightly run picks those up
# again by itself after a restart.
require "json"

now = Time.current
thinning = Agent.where.not(backup_thinning_started_at: nil)
                .select { |agent| Backup::VmThinning.running?(agent, now:) }.map(&:id)
backing_up = VmBackup.where(state: "pending").where("deadline_at > ?", now).distinct.pluck(:agent_id)
puts({ thinning: thinning.sort, backing_up: backing_up.sort }.to_json)
