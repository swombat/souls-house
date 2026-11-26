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
    interaction = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)

    result = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, interaction: interaction).call

    assert_not_requested stub
    assert_equal 409, result[:status]
    line = @chat.messages.where(role: "system").last
    assert_match(/did not respond: the model selected for this conversation, Claude Fable 5.1/, line.content)
    assert_includes line.content, "Use resident default"
    assert_equal line, interaction.reload.failure_notice_message
    assert_equal "failed", interaction.execution_state
    # #1118: the run carries the cause, and its line names the list and the model.
    assert_equal "model_not_on_list", interaction.response_body["error_kind"]
    assert_equal "model_not_on_list", interaction.failure_category
    assert_equal "the model selected for that conversation is no longer on its list of models for conversations (Claude Fable 5.1)",
      interaction.failure_reason
    assert_includes line.content, "is not on #{@agent.name}'s list of models for conversations"
    refute_match(/subscription/, line.content)
  end

  # JlRlKe: a pin that left the list runs on its successor when the list
  # carries one, and the room is told before the turn's model is resolved.
  test "a pin off the list runs on its successor, which the dispatch, the run and the room all name" do
    @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    @agent.update!(switchable_model_ids: [ "anthropic/claude-fable-5.2" ])
    successor = Agents::Sandbox.chaos_selection_for(@agent, model_id: "anthropic/claude-fable-5.2").fetch(:model)
    sent = nil
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| sent = JSON.parse(request.body) }
      .to_return(status: 200, body: ok_body(successor))

    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call

    assert_equal successor, sent["model"]
    assert_equal "anthropic/claude-fable-5.2", @seat.reload.model_id
    assert_equal successor, AgentRuntimeInteraction.last.model
    assert_match(/moved from Claude Fable 5\.1 to Claude Fable 5\.2/, @chat.messages.where(role: "system").last.content)
  end

  test "a rhythm-woken run on a seat pinned off the list with no successor carries the list kind, not unknown" do
    @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    @agent.update!(switchable_model_ids: [])
    stub = stub_request(:post, "https://agent.example.com/trigger")
    interaction = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)

    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, interaction: interaction,
      initiation_reason: "A rhythm is due here.").call

    assert_not_requested stub
    interaction.reload
    assert_equal "model_not_on_list", interaction.failure_category
    assert_includes interaction.failure_reason, "(Claude Fable 5.1)"
    refute_includes interaction.failure_reason, "isn't identified"
  end

  test "provider mismatch refusals give one explanation per run without hiding a later unknown failure" do
    @seat.select_model!("anthropic/claude-fable-5.1", by: users(:user_1))
    @agent.update!(model_id: "openai/gpt-6.1-sol")

    2.times do |attempt|
      @chat.messages.create!(role: "user", user: users(:user_1), content: "Try the selected model, attempt #{attempt + 1}.",
        suppress_automatic_dispatch: true)
      interaction = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
      assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
        result = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat, interaction: interaction).call
        assert_equal 409, result[:status]
        RunFailureNoticeJob.perform_now(interaction.id)
        RunFailureNoticeJob.perform_now(interaction.id)
      end

      line = @chat.messages.where(role: "system").order(:id).last
      assert_includes line.content, "Claude Fable 5.1, is from a different provider than the default model"
      assert_includes line.content, "Use resident default"
      assert_equal line, interaction.reload.failure_notice_message
      assert_equal "failed", interaction.execution_state
      # On the list, refused by the house's own check: that check's reason, never a provider refusal.
      assert_equal "model_selection_refused", interaction.failure_category
      assert_includes interaction.failure_reason, "the house couldn't use the model selected for that conversation (Claude Fable 5.1 is from a different provider"
    end

    unknown = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat)
    unknown.finish_execution!("failed")
    assert_equal "unknown", unknown.failure_category
    assert_difference -> { @chat.messages.where(role: "system").count }, 1 do
      RunFailureNoticeJob.perform_now(unknown.id)
      RunFailureNoticeJob.perform_now(unknown.id)
    end
    assert_includes unknown.reload.failure_notice_message.content, "the run failed and the cause isn't identified"
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


  # #864 slice 3: the payload carries plan_offer only while the offer is in
  # force; the runtime then adds the sentence to the run's first nudge.
  test "the runtime payload carries plan_offer only while the offer is in force" do
    agent = agents(:research_assistant)
    agent.account.update_columns(granted_plan: "colleagues", plan_offer_enabled: true)
    chat = agent.account.chats.create!(title: "Plan payload", manual_responses: true, agents: [ agent ])
    chat.messages.create!(role: "user", user: users(:user_1), content: "A long job.", suppress_automatic_dispatch: true)
    request = -> { ExternalAgentResponseRequest.new(agent: agent.reload, chat: chat, wake_source_kinds: [ "human" ]) }
    assert_nil request.call.send(:trigger_payload)[:plan_offer]

    agent.update!(plan_offer_enabled: true)
    assert_nil request.call.send(:trigger_payload)[:plan_offer], "not offered before being asked"
    # The one question is in the notices until answered; there is no wake line.
    asking = request.call
    assert_includes asking.send(:request_text), "[plan offer · asked until"
    assert_equal true, asking.send(:trigger_payload)[:plan_offer], "asked and offered in the same run"
    agent.answer_plan_offer!("on")
    assert_equal true, request.call.send(:trigger_payload)[:plan_offer]
    assert_not_includes request.call.send(:request_text), Agent::PlanOffer::OFFER, "no wake line"

    agent.answer_plan_offer!("off")
    assert_nil request.call.send(:trigger_payload)[:plan_offer]
  end

end
