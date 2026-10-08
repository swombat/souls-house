require "test_helper"
require "webmock/minitest"

# The conversation's model selection reaches Chaos, the prompt and the record
# as one value, resolved once when the turn starts.
class ExternalAgentResponseRequestModelTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      model_id: "anthropic/claude-opus-5.5",
      switchable_model_ids: [ "anthropic/claude-fable-5.1" ],
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )
    @chat = @agent.account.chats.new(model_id: "openrouter/auto", title: "Reading together", manual_responses: true)
    @chat.agent_ids = [ @agent.id ]
    @chat.save!
    @seat = ChatAgent.find_by!(chat: @chat, agent: @agent)
    @fable = Agents::Sandbox.chaos_selection_for(@agent, model_id: "anthropic/claude-fable-5.1").fetch(:model)
    @opus = Agents::Sandbox.chaos_model_for(@agent)
  end

  def ok_body(model)
    { status: "ok", returncode: 0, stdout: "", stderr: "",
      telemetry: { runtime: { provider: Agents::Sandbox.chaos_provider_for(@agent), model: model } } }.to_json
  end

  test "the selected model is sent to Chaos, told to the resident and recorded" do
    @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    sent = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| sent = JSON.parse(request.body) }
      .to_return(status: 200, body: ok_body(@fable))

    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call

    assert_equal @fable, sent["model"]
    assert_includes sent["request"], "You are running on Claude Fable 5.1"
    assert_equal @fable, AgentRuntimeInteraction.last.model
  end

  test "an answer keeps the model that produced it after the selection changes" do
    @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    stub_request(:post, "https://agent.example.com/trigger").to_return(status: 200, body: ok_body(@fable))
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    interaction = AgentRuntimeInteraction.last
    answer = @chat.messages.create!(role: "assistant", agent: @agent, content: "Read it.", runtime_interaction: interaction)

    @seat.select_model!("default", by: users(:user_1))

    assert_equal "Claude Fable 5.1", answer.reload.runtime_model_label
    assert_equal "Claude Fable 5.1", answer.as_json["runtime_model_label"]
    assert_nil @chat.messages.where(role: "system").last.runtime_model_label
  end

  test "a change made while a turn runs applies to the next turn, not this one" do
    sent = []
    stub_request(:post, "https://agent.example.com/trigger").to_return do |request|
      model = JSON.parse(request.body)["model"]
      sent << model
      # Someone switches while the turn is in flight.
      @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1)) if sent.size == 1
      { status: 200, body: ok_body(model) }
    end

    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    first = AgentRuntimeInteraction.last
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call

    assert_equal [ @opus, @fable ], sent
    assert_equal @opus, first.reload.model
    assert_equal @fable, AgentRuntimeInteraction.last.model
  end

  test "an unavailable selection is shown in the room and nothing runs on another model" do
    @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    @agent.update!(switchable_model_ids: [])
    stub = stub_request(:post, "https://agent.example.com/trigger")

    result = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call

    assert_not_requested stub
    assert_equal 409, result[:status]
    line = @chat.messages.where(role: "system").last
    assert_match(/did not respond: the model selected for this conversation, Claude Fable 5.1/, line.content)
    assert_includes line.content, "Use resident default"
  end

  test "another room keeps the default" do
    other = @agent.account.chats.new(model_id: "openrouter/auto", manual_responses: true)
    other.agent_ids = [ @agent.id ]
    other.save!
    @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    sent = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| sent = JSON.parse(request.body) }
      .to_return(status: 200, body: ok_body(@opus))

    ExternalAgentResponseRequest.new(agent: @agent, chat: other).call

    assert_equal @opus, sent["model"]
  end

end
