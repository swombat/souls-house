require "test_helper"

class CommitmentSweepJobTest < ActiveJob::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @lume = @account.agents.create!(name: "Lume", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Sweep", manual_responses: true)
    @chat.agents = [ @lume ]
    @chat.save!
  end

  test "activates due commitments once and leaves the rest" do
    now = Time.current
    due = Commitment.create!(agent: @lume, source_chat: @chat, text: "Due one", due_at: now + 1.minute)
    later = Commitment.create!(agent: @lume, source_chat: @chat, text: "Later one", due_at: now + 1.hour)
    travel_to(now + 2.minutes) do
      AgentRuntimeInteraction.stub(:live_activity_enabled?, true) do
        assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
          CommitmentSweepJob.perform_now
          CommitmentSweepJob.perform_now
        end
      end
    end
    assert_equal "activated", due.reload.status
    assert_equal "scheduled", later.reload.status
  end

  test "is in the production recurring schedule every minute" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"))["production"]["commitments"]
    assert_equal [ "CommitmentSweepJob", "every minute" ], [ schedule["class"], schedule["schedule"] ]
  end

end
