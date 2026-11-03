require "test_helper"

class ExternalAgentResponseRequestVoiceModeTest < ActiveSupport::TestCase

  # The trigger text says when the latest human turn was spoken in voice mode,
  # so the resident knows its reply will be heard, not read.
  test "the trigger text carries the voice mode note only while the latest human turn was spoken" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(title: "Spoken", manual_responses: true, agents: [ agent ])
    request = ExternalAgentResponseRequest.new(agent: agent, chat: chat, wake_source_kinds: [ "human" ])

    chat.messages.create!(role: "user", user: users(:user_1), content: "Typed.", suppress_automatic_dispatch: true)
    assert_not_includes request.send(:trigger_intro_text), "voice mode"

    chat.messages.create!(role: "user", user: users(:user_1), content: "Spoken.", voice_mode: true, suppress_automatic_dispatch: true)
    text = request.send(:trigger_intro_text)
    assert_includes text, "explicit human request"
    assert_includes text, ExternalAgentResponseRequest::VOICE_MODE_NOTE

    chat.messages.create!(role: "user", user: users(:user_1), content: "Back to typing.", suppress_automatic_dispatch: true)
    assert_not_includes request.send(:trigger_intro_text), "voice mode"
  end

  # After a spoken message and End, a later peer or scheduled wake must not be
  # told the person is listening: only a wake a human caused carries the note,
  # and the note never promises playback.
  test "the voice mode note is only for a wake a human caused and promises no playback" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(title: "Spoken then ended", manual_responses: true, agents: [ agent ])
    chat.messages.create!(role: "user", user: users(:user_1), content: "Spoken.", voice_mode: true, suppress_automatic_dispatch: true)

    [ [ "peer" ], [ "scheduled" ] ].each do |kinds|
      request = ExternalAgentResponseRequest.new(agent: agent, chat: chat, wake_source_kinds: kinds)
      assert_not_includes request.send(:trigger_intro_text), "voice mode", "#{kinds.first} wake"
    end

    human = ExternalAgentResponseRequest.new(agent: agent, chat: chat, wake_source_kinds: [ "human" ])
    assert_includes human.send(:trigger_intro_text), ExternalAgentResponseRequest::VOICE_MODE_NOTE
    # Playback is likely but not certain (the browser may have closed): "may", never a promise.
    assert_match(/may be read aloud/, ExternalAgentResponseRequest::VOICE_MODE_NOTE)
    assert_no_match(/will be read|will be heard|is listening/, ExternalAgentResponseRequest::VOICE_MODE_NOTE)
  end

  # On a phone eighty seconds of silence reads as nothing happening: the note
  # asks for an acknowledgement first and spoken-size updates while working.
  test "the voice mode note asks for an acknowledgement and twenty-second updates" do
    note = ExternalAgentResponseRequest::VOICE_MODE_NOTE
    assert_match(/Let me look at that/, note)
    assert_match(/before or alongside your first tool call/, note)
    assert_match(/every twenty seconds/, note)
    assert_match(/answer as its own short message/, note)
    assert_match(/Answer briefly in plain spoken sentences/, note)
  end

  # The runtime's silence clock can't read the transcript: the payload tells
  # it the turn was spoken, only for a human wake on a spoken latest turn.
  test "the runtime payload carries voice_mode only for a human wake on a spoken turn" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(title: "Spoken payload", manual_responses: true, agents: [ agent ])
    chat.messages.create!(role: "user", user: users(:user_1), content: "Typed.", suppress_automatic_dispatch: true)
    human = ExternalAgentResponseRequest.new(agent: agent, chat: chat, wake_source_kinds: [ "human" ])
    assert_nil human.send(:trigger_payload)[:voice_mode]

    chat.messages.create!(role: "user", user: users(:user_1), content: "Spoken, find me the vet.", voice_mode: true, suppress_automatic_dispatch: true)
    assert_equal true, human.send(:trigger_payload)[:voice_mode]
    composed = human.send(:trigger_intro_text)
    assert_includes composed, "every twenty seconds"

    [ [ "peer" ], [ "scheduled" ] ].each do |kinds|
      other = ExternalAgentResponseRequest.new(agent: agent, chat: chat, wake_source_kinds: kinds)
      assert_nil other.send(:trigger_payload)[:voice_mode], "#{kinds.first} wake"
    end
  end

end
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

  test "source hints are persisted through both reserved and legacy dispatch paths" do
    [ true, false ].each do |live_activity|
      sent = nil
      stub_request(:post, "https://agent.example.com/trigger")
        .with { |request| sent = JSON.parse(request.body) }
        .to_return(status: 200, body: ok_body(@opus))
      AgentRuntimeInteraction.stub(:live_activity_enabled?, live_activity) do
        ResidentTurn.stub(:enabled?, false) do
          result = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat,
            wake_source_kinds: [ "human", "peer" ]).call
          assert_equal 200, result[:status]
        end
      end
      interaction = @chat.agent_runtime_interactions.order(:id).last
      assert_equal [ "human", "peer" ], interaction.wake_source_kinds
      assert_includes interaction.request_text, "requests from both a human and a fellow resident"
      assert_includes sent.fetch("request"), "requests from both a human and a fellow resident"
      refute_includes sent.fetch("request"), "The user pressed the agent button"
    end
  end

  test "dispatch preserves reserved provenance instead of replacing it with caller hints" do
    interaction = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat,
      wake_source_kinds: [ "peer" ])
    sent = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| sent = JSON.parse(request.body) }
      .to_return(status: 200, body: ok_body(@opus))
    ResidentTurn.stub(:enabled?, false) do
      result = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, interaction: interaction,
        wake_source_kinds: [ "human" ]).call
      assert_equal 200, result[:status]
    end
    assert_equal [ "peer" ], interaction.reload.wake_source_kinds
    assert_includes sent.fetch("request"), "A fellow resident requested"
    refute_includes sent.fetch("request"), "This trigger is itself the user asking"
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
