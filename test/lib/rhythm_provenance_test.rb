require "test_helper"

class RhythmProvenanceTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @rhythm = Rhythm.create!(
      account: @agent.account, creator: users(:user_1), agents: [ @agent ],
      title: "Returning", opening: "Please reflect.", cadence: "daily",
      time_of_day: "09:00", timezone: "UTC"
    )
    @occurrence = @rhythm.fire!(manual: true, request_key: SecureRandom.uuid).occurrence
  end

  test "opening is creator attributed and has persistent provenance after deletion" do
    message = @occurrence.message
    assert_equal @rhythm.creator, message.user
    assert_equal "Returning", message.rhythm_provenance[:title]
    assert message.rhythm_provenance[:manual]
    @rhythm.update!(title: "Something else")
    assert_equal "Returning", message.reload.rhythm_provenance[:title]
    @rhythm.destroy!
    assert_equal "Returning", message.reload.rhythm_provenance[:title]
    assert_nil message.rhythm_provenance[:rhythm_url]
    assert_equal "Returning", @occurrence.chat.transcript_for_api.first[:rhythm_provenance][:title]
  end

  test "runtime context clearly distinguishes standing invitation and includes off switch" do
    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @occurrence.chat)
    text = request.send(:request_text)
    assert_includes text, "scheduled rhythm"
    assert_includes text, "RHYTHM INVITATION"
    assert_includes text, "/api/v1/rhythms/#{@rhythm.to_param}/pause"
    assert_not_includes text, "The user pressed the agent button"
    @occurrence.chat.messages.create!(role: "user", user: @rhythm.creator, content: "A new actual request",
      suppress_automatic_dispatch: true)
    fresh = ExternalAgentResponseRequest.new(agent: @agent, chat: @occurrence.chat)
    assert_nil fresh.send(:rhythm_invitation)
  end

  test "solo opening creates only the explicit rhythm dispatch" do
    assert_equal 1, @occurrence.chat.messages.joins(:message_dispatch).count
    assert_equal "rhythm", @occurrence.message.message_dispatch.kind
    assert_empty @occurrence.chat.agent_runtime_interactions
  end

  test "resident opening is not a human message and preserves provenance and runtime controls" do
    rhythm = Rhythm.create!(
      account: @agent.account, creator_agent: @agent, agents: [ @agent ],
      title: "Resident returning", opening: "My saved invitation", cadence: "daily",
      time_of_day: "09:00", timezone: "UTC"
    )
    occurrence = nil
    assert_enqueued_jobs 1, only: MessageDispatchJob do
      occurrence = rhythm.fire!(manual: true, request_key: "resident").occurrence
    end
    opening = occurrence.message
    assert_equal "assistant", opening.role
    assert_equal @agent, opening.agent
    assert_nil opening.user
    assert_nil occurrence.creator
    assert_equal @agent, occurrence.creator_agent
    assert_equal @agent.name, occurrence.creator_label
    assert_nil opening.runtime_interaction
    assert_nil opening.message_dispatch.user
    assert_equal "rhythm", opening.message_dispatch.kind
    assert_empty occurrence.chat.agent_runtime_interactions
    assert_equal "agent", opening.rhythm_provenance[:creator_type]
    request = ExternalAgentResponseRequest.new(agent: @agent, chat: occurrence.chat)
    text = request.send(:request_text)
    assert_includes text, "RHYTHM INVITATION"
    assert_includes text, @agent.name
    assert_includes text, "/api/v1/rhythms/#{rhythm.to_param}/leave"
    assert_not_includes text, "The user pressed the agent button"
    occurrence.chat.messages.create!(role: "assistant", agent: @agent, content: "A reply in the round")
    assert_equal occurrence, ExternalAgentResponseRequest.new(agent: @agent, chat: occurrence.chat).send(:rhythm_invitation)
    occurrence.chat.messages.create!(role: "user", user: users(:user_1), content: "A real fresh request", suppress_automatic_dispatch: true)
    assert_nil ExternalAgentResponseRequest.new(agent: @agent, chat: occurrence.chat).send(:rhythm_invitation)
    rhythm.destroy!
    assert_equal "Resident returning", opening.reload.rhythm_provenance[:title]
    assert_equal "agent", opening.rhythm_provenance[:creator_type]
    assert_nil opening.rhythm_provenance[:rhythm_url]
    assert_equal @agent.name, occurrence.reload.creator_label
  end

end
