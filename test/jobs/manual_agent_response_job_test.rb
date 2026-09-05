require "test_helper"
require "webmock/minitest"

class ManualAgentResponseJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Harness chat", manual_responses: true, agents: [ @agent ])
    @agent.update!(
      runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0
    )
  end

  test "external agent receives a trigger instead of local inference" do
    trigger = stub_request(:post, "https://agent.example.com/trigger")
      .with(headers: { "Authorization" => "Bearer tr_valid" })
      .to_return(status: 200, body: { status: "accepted" }.to_json)

    assert_no_difference "Message.count" do
      ManualAgentResponseJob.perform_now(@chat, @agent)
    end
    assert_requested trigger
  end

  test "offline external agent retains unreachable feedback" do
    @agent.update!(runtime: "offline", health_state: "unhealthy", consecutive_health_failures: 6)
    assert_difference "Message.count", 1 do
      ManualAgentResponseJob.perform_now(@chat, @agent)
    end
    assert_equal @agent, @chat.messages.last.agent
    assert_includes @chat.messages.last.content, "currently unreachable"
  end

  test "archived conversations and removed participants never dispatch" do
    ExternalAgentResponseRequest.stub(:new, ->(**) { flunk "must not dispatch" }) do
      @chat.archive!
      ManualAgentResponseJob.perform_now(@chat, @agent)
      @chat.unarchive!
      @chat.chat_agents.delete_all
      ManualAgentResponseJob.perform_now(@chat, @agent)
      assert_empty @chat.agent_runtime_interactions
    end
  end

end
