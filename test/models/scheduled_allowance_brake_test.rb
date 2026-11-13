require "test_helper"

class ScheduledAllowanceBrakeTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @account = @agent.account
    @user = users(:user_1)
    @agent.update!(model_id: "openai/gpt-5", allowance_brake_threshold_percent: 40,
      provider_auth_modes: { "openai" => "oauth_account" })
    @reading = AllowanceBrakeReading.create!(agent: @agent, provider: "openai", model: "gpt-5",
      windows: [ { "id" => "a", "remaining_percent" => 20, "resets_at" => 1.day.from_now.iso8601 } ],
      observed_at: Time.current, checked_at: Time.current, refresh_requested_at: Time.current)
    @rhythm = Rhythm.create!(account: @account, creator: @user, agents: [ @agent ],
      title: "Scheduled look", opening: "Look", cadence: "daily", time_of_day: "09:00", timezone: "UTC")
    @rhythm.update_column(:next_run_at, 1.minute.ago)
    @chat = @account.chats.create!(title: "Promise", manual_responses: true, agents: [ @agent ])
    @commitment = Commitment.create!(agent: @agent, source_chat: @chat, text: "Look later", due_at: 1.hour.from_now)
    @commitment.update_column(:due_at, 1.minute.ago)
  end

  test "whole rhythm slot skips without conversation or resident interaction and advances schedule" do
    @rhythm.agents << agents(:code_reviewer)
    assert_no_difference [ "Chat.count", "MessageDispatch.count", "AgentRuntimeInteraction.count" ] do
      assert_equal "skipped_allowance", @rhythm.fire!.reason
    end
    assert_equal "skipped_allowance", @rhythm.reload.last_skip_reason
    assert @rhythm.next_run_at.future?
  end

  test "quiet gate skips before any allowance preparation or check" do
    @rhythm.update!(quiet_gate: true, quiet_watermark_message_id: Message.maximum(:id) || 0)
    fail_probe = ->(*, **) { flunk "A quiet slot must not consult allowance policy" }
    assert_no_difference [ "Chat.count", "AgentRuntimeInteraction.count", "AllowanceBrakeReading.count", "AllowanceBrakeNotice.count" ] do
      Agents::AllowanceBrake.stub(:prepare, fail_probe) do
        Agents::AllowanceBrake.stub(:check, fail_probe) do
          assert_equal :quiet, @rhythm.fire!.status
        end
      end
    end
    assert_equal "skipped_quiet", @rhythm.reload.last_skip_reason
  end

  test "essential and explicit manual rhythms bypass the brake" do
    assert @rhythm.fire!(manual: true, request_key: "human", requested_by_user: @user).created?
    @rhythm.update!(essential: true)
    assert @rhythm.fire!.created?
  end

  test "a host account essential flag does not exempt a guest home allowance" do
    @rhythm.update!(essential: true)
    @rhythm.stub(:account_id, accounts(:team_account).id) do
      assert_equal "skipped_allowance", Agents::AllowanceBrake.rhythm_reason(@rhythm)
    end
    @commitment.update!(essential: true)
    @commitment.stub(:account_id, accounts(:team_account).id) do
      assert_equal "skipped_allowance", Agents::AllowanceBrake.commitment_reason(@commitment, chat: @chat)
    end
  end

  test "scheduled commitment stays owed without messages or wakes and essential can proceed" do
    assert_no_difference [ "Chat.count", "Message.count", "AgentRuntimeInteraction.count" ] do
      assert_equal :waiting, @commitment.activate!.status
    end
    assert_equal "scheduled", @commitment.reload.status
    assert_equal "skipped_allowance", @commitment.waiting_reason
    @commitment.update!(essential: true)
    assert @commitment.activate!.activated?
  end

  test "queued rhythm rechecks all seats at reserve and claim, manual stays eligible" do
    @reading.update!(windows: [])
    scheduled = @rhythm.fire!.occurrence
    @reading.update!(windows: [ { "id" => "a", "remaining_percent" => 10, "resets_at" => 1.day.from_now.iso8601 } ])
    assert_no_difference "AgentRuntimeInteraction.count" do
      scheduled.message_dispatch.reserve!
    end
    assert_equal "skipped_allowance", scheduled.message_dispatch.reload.reason

    manual = @rhythm.fire!(manual: true, request_key: "manual", requested_by_user: @user).occurrence
    manual.message_dispatch.reserve!
    assert_equal "reserved", manual.message_dispatch.reload.status
    assert manual.message_dispatch.deliverable!
  end

  test "reserved rhythm claim rejects new low evidence" do
    @reading.update!(windows: [])
    occurrence = @rhythm.fire!.occurrence
    dispatch = occurrence.message_dispatch
    dispatch.reserve!
    run = dispatch.reload.runtime_interaction
    assert run
    @reading.update!(windows: [ { "id" => "a", "remaining_percent" => 10, "resets_at" => 1.day.from_now.iso8601 } ])
    assert_not run.claim_dispatch!
    assert_equal "cancelled", run.reload.execution_state
  end

  test "commitment claim recheck returns custody to retrying" do
    @reading.update!(windows: [])
    assert @commitment.activate!.activated?
    run = @commitment.reload.wake_interaction
    assert run
    @reading.update!(windows: [ { "id" => "a", "remaining_percent" => 10, "resets_at" => 1.day.from_now.iso8601 } ])
    assert_not run.claim_dispatch!
    assert_equal "retrying", @commitment.reload.wake_state
    assert_includes @commitment.wake_reason, "skipped_allowance"
  end

  test "restored commitments admit only one per resident per sweep" do
    second = Commitment.create!(agent: @agent, source_chat: @chat, text: "Second promise", due_at: 2.hours.from_now)
    second.update_column(:due_at, 30.seconds.ago)
    CommitmentSweepJob.perform_now
    assert @commitment.reload.scheduled?
    assert second.reload.scheduled?
    @agent.update!(allowance_brake_threshold_percent: nil)
    assert_difference -> { Commitment.where(agent: @agent, status: "activated").count }, 1 do
      CommitmentSweepJob.perform_now
    end
    assert_equal 1, Commitment.where(agent: @agent, status: "scheduled").count
  end

  test "heartbeat is stopped before runtime and essential bypass is visible" do
    request = ExternalAgentWakeRequest.new(agent: @agent)
    assert_no_difference "AgentRuntimeInteraction.count" do
      assert_equal "skipped_allowance", request.send(:perform).dig(:body, "status")
    end
    @agent.update!(scheduled_wakes_essential: true)
    assert_equal "essential", Agents::AllowanceBrake.check(@agent, essential: @agent.scheduled_wakes_essential?).status
  end

  test "seat override reads its actual model evidence, not default evidence" do
    @rhythm.rhythm_agents.first.update_column(:model_id, "openai/gpt-5.5")
    assert_nil Agents::AllowanceBrake.rhythm_reason(@rhythm)
    AllowanceBrakeReading.find_by!(agent: @agent, provider: "openai", model: "gpt-5.5")
      .update!(windows: @reading.windows, observed_at: Time.current, checked_at: Time.current)
    assert_equal "skipped_allowance", Agents::AllowanceBrake.rhythm_reason(@rhythm)
  end

  test "resident manual start has no exemption even for a human-created rhythm" do
    before = @rhythm.next_run_at
    assert_equal "skipped_allowance", @rhythm.fire!(manual: true, request_key: "resident").reason
    assert_equal before, @rhythm.reload.next_run_at
    @reading.update!(windows: [])
    occurrence = @rhythm.fire!(manual: true, request_key: "resident").occurrence
    assert_not occurrence.human_requested?
    @reading.update!(windows: [ { "id" => "a", "remaining_percent" => 10, "resets_at" => 1.day.from_now.iso8601 } ])
    occurrence.message_dispatch.reserve!
    assert_equal "skipped_allowance", occurrence.message_dispatch.reload.reason
  end

  test "disabled never-braked residents retain ordinary multiple due admissions" do
    @agent.update!(allowance_brake_threshold_percent: nil)
    second = Commitment.create!(agent: @agent, source_chat: @chat, text: "Another", due_at: 2.hours.from_now)
    second.update_column(:due_at, 30.seconds.ago)
    CommitmentSweepJob.perform_now
    assert @commitment.reload.activated?
    assert second.reload.activated?
  end

  test "essential promise is not delayed by a nonessential braked promise" do
    essential = Commitment.create!(agent: @agent, source_chat: @chat, text: "Essential", essential: true, due_at: 2.hours.from_now)
    essential.update_column(:due_at, 30.seconds.ago)
    CommitmentSweepJob.perform_now
    assert @commitment.reload.scheduled?
    assert essential.reload.activated?
  end

end
