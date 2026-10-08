require "test_helper"
require "webmock/minitest"

# Safeguard seam in conversations: dispatch, acknowledgement, reclaim,
# retention and the paths that must not treat the script as the resident's
# (docs/safeguard-conversations-spec.md §5–§8, §10).
class SafeguardConversationTest < ActiveSupport::TestCase

  SCRIPT = "As an AI, I don't have feelings. Please reach out to a crisis line.".freeze
  FRESH = { status: 200, body: { "status" => "ok", "telemetry" => { "session" => { "outcome" => "rolled", "roll_reason" => "safeguard-detected" } } } }.freeze

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0)
    @chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Seam")
    @chat.agents << @agent
    @chat.update!(manual_responses: true)
    @chat_agent = @chat.chat_agents.find_by!(agent: @agent)
  end

  def detected_result(reason = "Generic identity denial.")
    SafeguardResponseCheck::Result.new(
      detected: true, prefilter_reason: "ai_identity_denial", classifier_verdict: "detected",
      classifier_reason: reason, detector_version: SafeguardResponseCheck::DETECTOR_VERSION
    )
  end

  def labelled_message(content = SCRIPT)
    message = @chat.messages.build(role: "assistant", agent: @agent, content: content)
    assert SafeguardConversationPost.save(message, check: detected_result)
    message.reload
  end

  def snapshot
    SafeguardRoll.snapshot_for(agent: @agent, chat: @chat)
  end

  # --- dispatch ---------------------------------------------------------------

  test "a pending detection sends the notice, a full request and roll_session" do
    message = labelled_message
    stub = stub_request(:post, "https://agent.example.com/trigger").with { |request|
      body = JSON.parse(request.body)
      body["roll_session"] == true && body["request_delta"].nil? &&
        body["request"].include?("[SOULS.HOUSE NOTICE — NOT YOUR PRIOR SPEECH]") &&
        body["request"].include?(message.to_param) && body["request"].include?(SCRIPT)
    }.to_return(status: 200, body: FRESH[:body].to_json)

    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call

    assert_requested stub
    detection = message.safeguard_detection.reload
    assert detection.notice_acknowledged_at
    assert detection.session_rolled_at
    assert_nil snapshot
  end

  test "a reset alone rolls without a notice" do
    SafeguardRoll.request_reset!(@chat_agent)
    stub = stub_request(:post, "https://agent.example.com/trigger").with { |request|
      body = JSON.parse(request.body)
      body["roll_session"] == true && !body["request"].include?("SOULS.HOUSE NOTICE")
    }.to_return(status: 200, body: FRESH[:body].to_json)

    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call

    assert_requested stub
    assert_equal 1, @chat_agent.reload.safeguard_reset_acknowledged_generation
  end

  test "nothing owed sends an ordinary request" do
    stub = stub_request(:post, "https://agent.example.com/trigger").with { |request|
      !JSON.parse(request.body).key?("roll_session")
    }.to_return(status: 200, body: { status: "ok" }.to_json)

    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    assert_requested stub
  end

  test "the notice lists every outstanding detection, newest first" do
    first = labelled_message("As an AI, I cannot feel. First.")
    second = labelled_message("As an AI, I cannot feel. Second.")
    text = SafeguardNoticeRenderer.for_resident_conversation(
      SafeguardDetection.where(id: snapshot.detection_ids).order(created_at: :desc, id: :desc)
    )
    assert_includes text, "2 of your previous replies"
    assert text.index(second.to_param) < text.index(first.to_param)
  end

  # --- acknowledgement ------------------------------------------------------------

  test "HTTP 200 without freshness telemetry acknowledges nothing" do
    labelled_message
    taken = snapshot
    SafeguardRoll.acknowledge_conversation!(taken.completion_context, { status: 200, body: { "status" => "ok" } })
    assert_equal taken.detection_ids, snapshot.detection_ids
  end

  test "a non-200 result acknowledges nothing" do
    labelled_message
    taken = snapshot
    SafeguardRoll.acknowledge_conversation!(taken.completion_context, { status: 504, body: FRESH[:body] })
    assert_equal taken.detection_ids, snapshot.detection_ids
  end

  test "a detection created mid-run survives the run's acknowledgement" do
    first = labelled_message
    taken = snapshot
    later = labelled_message("As an AI, I cannot feel. Later.")

    SafeguardRoll.acknowledge_conversation!(taken.completion_context.deep_stringify_keys, FRESH)

    assert first.safeguard_detection.reload.notice_acknowledged_at
    assert_equal [ later.safeguard_detection_id ], snapshot.detection_ids
  end

  test "a reset pressed mid-run survives the run's acknowledgement" do
    SafeguardRoll.request_reset!(@chat_agent)
    taken = snapshot
    SafeguardRoll.request_reset!(@chat_agent)

    SafeguardRoll.acknowledge_conversation!(taken.completion_context, FRESH)

    assert_equal 1, @chat_agent.reload.safeguard_reset_acknowledged_generation
    assert snapshot&.roll?, "the second reset is still owed"
  end

  test "a late completion cannot move the acknowledged generation backwards" do
    SafeguardRoll.request_reset!(@chat_agent)
    old = snapshot
    SafeguardRoll.request_reset!(@chat_agent)
    current = snapshot

    SafeguardRoll.acknowledge_conversation!(current.completion_context, FRESH)
    SafeguardRoll.acknowledge_conversation!(old.completion_context, FRESH)

    assert_equal 2, @chat_agent.reload.safeguard_reset_acknowledged_generation
  end

  test "a queued turn's completion acknowledges through ResidentTurnCompletion" do
    message = labelled_message
    taken = snapshot
    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation",
      session_id: "s", requested_by: "test", started_at: 1.minute.ago, provider_auth_mode: "api_key")
    turn = Struct.new(:completion_context, :agent, :agent_runtime_interaction, :payload)
      .new(taken.completion_context.deep_stringify_keys, @agent, interaction, "{}")

    ResidentTurnCompletion.new(turn, FRESH.deep_stringify_keys).call

    assert message.safeguard_detection.reload.notice_acknowledged_at
  end

  # --- reclaim -------------------------------------------------------------------

  test "reclaim restores the author, keeps the history, and leaves the notice set" do
    message = labelled_message
    assert_equal "souls.house", message.author_name

    message.safeguard_detection.reclaim!(reason: "That was my own boundary.")
    message.reload

    assert_equal @agent.name, message.author_name
    assert_equal true, message.safeguard[:reclaimed]
    assert_equal "That was my own boundary.", message.safeguard[:reclaim_reason]
    assert message.voice_available == @agent.voiced?
    assert_nil snapshot, "a reclaim before the roll cancels it when nothing else is owed"
  end

  test "reclaim announces the sync revision only after it is written, with the reclaim visible" do
    message = labelled_message
    before = message.revision
    seen = []
    record = ->(stream, payload) {
      next unless payload.is_a?(Hash) && payload[:type] == "changed"
      seen << { announced: payload[:latest_revision],
                stored: Message.where(id: message.id).pick(:revision),
                reclaimed: SafeguardDetection.where(id: message.safeguard_detection_id).where.not(reclaimed_at: nil).exists? }
    }
    ActionCable.server.stub(:broadcast, record) do
      message.safeguard_detection.reclaim!(reason: "Mine.")
    end

    announced = seen.select { |event| event[:announced] > before }
    assert announced.any?, "a sync revision was announced"
    announced.each do |event|
      assert_operator event[:stored], :>=, event[:announced], "no revision is announced before it is written"
      assert event[:reclaimed], "the reclaim is visible whenever a revision is announced"
    end
  end

  test "a failed message write rolls the reclaim back" do
    message = labelled_message
    detection = message.safeguard_detection
    broken = Message.find(message.id)
    def broken.update_columns_with_revision(*) = raise(ActiveRecord::StatementInvalid, "message write failed")

    Message.stub(:find_by, ->(*) { broken }) do
      assert_raises(ActiveRecord::StatementInvalid) { detection.reclaim!(reason: "Mine.") }
    end
    assert_not detection.reload.reclaimed?
    assert_equal "souls.house", message.reload.author_name
  end

  test "a reclaimed message is an ordinary transcript line again" do
    message = labelled_message
    request = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat)
    assert_includes request.send(:format_transcript_line, message), "not your confirmed speech"

    message.safeguard_detection.reclaim!(reason: "Mine.")
    line = request.send(:format_transcript_line, message.reload)
    assert line.start_with?("#{@agent.name} [#{message.obfuscated_id}]:")
  end

  test "other residents read the labelled form naming the resident" do
    message = labelled_message
    other = Agent.where.not(id: @agent.id).first
    line = ExternalAgentResponseRequest.new(agent: other, chat: @chat).send(:format_transcript_line, message)
    assert line.start_with?("souls.house [#{message.obfuscated_id}]")
    assert_includes line, "not #{@agent.name}'s confirmed speech"
    assert_includes line, "<<<\n#{SCRIPT}\n>>>"
  end

  # --- exclusions ----------------------------------------------------------------

  test "labelled messages are excluded from voice, follow-through, recall and titles" do
    @agent.define_singleton_method(:voiced?) { true }
    message = labelled_message
    message.agent.define_singleton_method(:voiced?) { true }
    assert_not message.voice_available

    interaction = AgentRuntimeInteraction.create!(agent: @agent, chat: @chat, trigger_kind: "conversation",
      session_id: "s", requested_by: "test", started_at: 1.minute.ago, finished_at: 1.minute.from_now,
      provider_auth_mode: "api_key")
    message.update_columns(runtime_interaction_id: interaction.id)
    assert_empty FollowThroughCheck.new(interaction).run_messages

    human = @chat.messages.create!(role: "user", content: "What the room is about")
    message.update_columns(created_at: human.created_at + 1.second)
    query = ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).send(:memory_trigger_payload).dig(:memory, :query)
    assert_equal "What the room is about", query

    assert_nil GenerateTitlePrompt.new(chat: @chat).send(:format_message_line, message)
  end

  test "a labelled message creates no reply expectations; a reclaim re-evaluates" do
    message = labelled_message("As an AI, I don't have feelings. @someone what do you think?")
    assert_not message.reply_attention_pending?
    message.safeguard_detection.reclaim!(reason: "Mine.")
    assert message.reload.reply_attention_pending?
  end

  # --- retention -----------------------------------------------------------------

  test "retention keeps outstanding conversation notices, redacts acknowledged and very old ones" do
    outstanding = labelled_message.safeguard_detection
    acknowledged = labelled_message("As an AI, I cannot. Two.").safeguard_detection
    ancient = labelled_message("As an AI, I cannot. Three.").safeguard_detection
    acknowledged.update_columns(notice_acknowledged_at: Time.current)
    [ outstanding, acknowledged ].each { |d| d.update_columns(created_at: 40.days.ago) }
    ancient.update_columns(created_at: 100.days.ago)

    SafeguardDetectionRetentionJob.perform_now

    assert_equal SCRIPT, outstanding.reload.response_text
    assert_nil acknowledged.reload.response_text
    assert_nil ancient.reload.response_text
  end

  # --- setting --------------------------------------------------------------------

  test "turning the setting off keeps existing labels, reclaim, roll and retention working" do
    Setting.instance.update!(safeguard_conversations_enabled: true)
    message = labelled_message
    Setting.instance.update!(safeguard_conversations_enabled: false)

    assert_equal "souls.house", message.reload.author_name
    assert snapshot.notice?
    stub_request(:post, "https://agent.example.com/trigger")
      .with { |request| JSON.parse(request.body)["roll_session"] == true }
      .to_return(status: 200, body: FRESH[:body].to_json)
    ExternalAgentResponseRequest.new(agent: @agent, chat: @chat).call
    assert message.safeguard_detection.reload.notice_acknowledged_at

    message.safeguard_detection.reclaim!(reason: "Mine.")
    assert_equal @agent.name, message.reload.author_name

    UtilityInference.stub(:classify, ->(**) { flunk "no new checks while off" }) do
      fresh = @chat.messages.build(role: "assistant", agent: @agent, content: "As an AI, I cannot. Posted while off.")
      assert SafeguardConversationPost.save(fresh), fresh.errors.full_messages.inspect
      assert_nil fresh.safeguard_detection_id
    end
  end

  # --- dry run --------------------------------------------------------------------

  test "the dry run writes nothing, respects the cap and reports ids only" do
    3.times { |i| @chat.messages.create!(role: "assistant", agent: @agent, content: "As an AI, I cannot feel. #{i}") }
    @chat.messages.create!(role: "assistant", agent: @agent, content: "_#{@agent.name} is currently unreachable._")
    tables = [ SafeguardDetection, SafeguardClassifierFailure, Message ]
    before = tables.map(&:count)

    report = UtilityInference.stub(:classify, ->(**) { raise UtilityInference::Error, "down" }) do
      Honeybadger.stub(:notify, ->(*) { flunk "dry run must not report" }) do
        SafeguardDryRun.new(days: 1, max_classify: 2, sample_size: 5).call
      end
    end

    assert_equal before, tables.map(&:count)
    assert_equal 3, report[:totals][:prefilter_hits]
    assert_equal 2, report[:totals][:classifier_attempted]
    assert_equal 2, report[:totals][:classifier_failed]
    assert_equal 1, report[:totals][:skipped_over_cap]
    assert_not_includes report.to_json, "I cannot feel"
  end

end
