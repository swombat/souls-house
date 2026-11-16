require "test_helper"

# ops/deploy/backup-in-flight.rb: what the deploy asks the live house before
# it switches releases (worker.py, wait_for_backups).
class HostDeployBackupWaitTest < ActiveSupport::TestCase

  def answer
    output, = capture_io { load Rails.root.join("ops/deploy/backup-in-flight.rb") }
    JSON.parse(output.lines.last)
  end

  test "nothing running answers two empty lists" do
    assert_equal({ "thinning" => [], "backing_up" => [] }, answer)
  end

  test "a fresh thinning mark is listed and an abandoned one is not" do
    fresh, stale = agents(:research_assistant), agents(:code_reviewer)
    fresh.update_columns(backup_thinning_started_at: 2.minutes.ago)
    stale.update_columns(backup_thinning_started_at: (Backup::VmThinning::CLAIM_SECONDS + 60).seconds.ago)

    assert_equal [ fresh.id ], answer.fetch("thinning")
  end

  test "a pending backup inside its deadline is listed; a settled or expired one is not" do
    backing_up, done, late = agents(:research_assistant), agents(:code_reviewer), agents(:with_save_memory_tool)
    backup!(backing_up, state: "pending", deadline_at: 5.minutes.from_now)
    backup!(done, state: "verified", deadline_at: 5.minutes.from_now)
    backup!(late, state: "pending", deadline_at: 1.minute.ago)

    assert_equal [ backing_up.id ], answer.fetch("backing_up")
    assert_equal [], answer.fetch("thinning")
  end

  private

  def backup!(agent, **attributes)
    placement = AgentPlacement.create!(agent:, backend: "hetzner_cloud", state: "pending")
    enrollment, = RunnerEnrollment.mint!(placement:)
    command = RunnerCommand.enqueue!(enrollment:, kind: "backup_resident", payload: {})
    VmBackup.create!(agent:, runner_command: command, checkpoint_file_digest: "d" * 64, **attributes)
  end

end
