require "test_helper"

class Chats::RuntimeAdmissionTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @group = @account.chats.create!(title: "Existing history", manual_responses: true, agents: [ agents(:code_reviewer) ])
    @legacy_chat = @account.chats.create!(title: "Historical base-model chat")
    sign_in users(:user_1)
  end

  test "direct web participant and assignment requests reject every unavailable runtime" do
    %w[deprecated inline migrating provisioning].each do |runtime|
      @agent.update_columns(runtime: runtime)
      assert_no_difference [ "Message.count", "ChatAgent.count" ] do
        post account_chat_participant_path(@account, @group), params: { agent_id: @agent.to_param }
        assert_response :not_found
        post account_chat_agent_assignment_path(@account, @legacy_chat), params: { agent_id: @agent.to_param }
        assert_response :not_found
      end
      assert_not @legacy_chat.reload.manual_responses?
    end
  end

  test "inactive residents are rejected while paused offline residents remain eligible" do
    @agent.update!(active: false)
    post account_chat_participant_path(@account, @group), params: { agent_id: @agent.to_param }
    assert_response :not_found
    @agent.update!(active: true, paused: true, runtime: "offline")
    post account_chat_participant_path(@account, @group), params: { agent_id: @agent.to_param }
    assert_redirected_to account_chat_path(@account, @group)
    assert_includes @group.reload.agents, @agent
  end

end
