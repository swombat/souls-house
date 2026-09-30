require "test_helper"

class SingleResidentResponseTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @resident = @account.agents.create!(name: "Solo", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Solo room", manual_responses: true)
    @chat.agents = [ @resident ]
    @chat.save!
  end

  test "human message wakes the only resident without a mention" do
    assert_enqueued_jobs 1, only: ManualAgentResponseJob do
      message = post_human
      assert message.single_resident_response_triggered
      run = @chat.agent_runtime_interactions.sole
      assert_equal "queued", run.execution_state
      assert_equal @resident, run.agent
      assert @chat.agent_response_active?(@resident)
    end
  end

  test "opening message also wakes the only resident" do
    assert_enqueued_jobs 1, only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      Chat.create_with_message!({ account: @account, title: "New room", manual_responses: true },
        message_content: "Hello", user: @user, agent_ids: [ @resident.id ])
    end
  end

  test "resident replies and anonymous or system messages never self-trigger" do
    assert_no_enqueued_jobs only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      @chat.messages.create!(role: "assistant", agent: @resident, content: "Reply")
      @chat.messages.create!(role: "user", content: "Anonymous")
      @chat.messages.create!(role: "system", content: "System")
    end
  end

  test "multiple residents do not automatically trigger even if only one is available" do
    @chat.agents << @account.agents.create!(name: "Other", system_prompt: "Test", runtime: "offline", active: false)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "unavailable resident is not triggered" do
    @resident.update!(active: false)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "archived rooms do not trigger" do
    @chat.update!(archived_at: Time.current)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "already responding resident is not started again" do
    AgentRuntimeInteraction.reserve!(agent: @resident, chat: @chat)
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { post_human }
  end

  test "a second message while queued does not reserve another wake" do
    post_human
    assert_no_difference "AgentRuntimeInteraction.count" do
      @chat.messages.create!(role: "user", user: @user, content: "One more thought")
    end
  end

  test "attachment-only opening messages wake the resident" do
    assert_enqueued_jobs 1, only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      Chat.create_with_message!({ account: @account, title: "File room", manual_responses: true },
        user: @user, agent_ids: [ @resident.id ],
        files: [ { io: StringIO.new("attachment"), filename: "note.txt", content_type: "text/plain" } ])
    end
  end

  test "edits do not wake the resident again" do
    message = post_human
    assert_no_enqueued_jobs(only: [ AllAgentsResponseJob, ManualAgentResponseJob ]) { message.update!(content: "Edited") }
  end

  test "rolled back messages never wake a resident" do
    assert_no_enqueued_jobs only: [ AllAgentsResponseJob, ManualAgentResponseJob ] do
      Message.transaction(requires_new: true) do
        post_human
        raise ActiveRecord::Rollback
      end
    end
  end

  private

  def post_human
    @chat.messages.create!(role: "user", user: @user, content: "Hello resident")
  end

end
