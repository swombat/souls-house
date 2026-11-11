require "test_helper"

class ChatWorkStatusTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(title: "Work", model_id: "openrouter/auto", agents: [ @agent ], manual_responses: true)
  end

  test "untracked is not idle and every serializer supplies the structured shape" do
    expected = { state: nil, reason: nil, since: nil, revision: 0, human_replied_since: nil }
    assert_equal expected, @chat.work_status_json
    assert_equal expected.stringify_keys, @chat.as_json["work_status"].stringify_keys
    assert_equal expected.stringify_keys, @chat.as_json(as: :sidebar_json)["work_status"].stringify_keys
    assert_equal expected, Api::App::V1::Presenter.conversation(@chat)[:work_status]
  end

  test "explicit transitions retry without touching timestamps and clearing does not claim idle" do
    travel_to Time.current.change(usec: 0) do
      change("working")
      assert_equal 1, @chat.work_status_revision
      since = @chat.work_status_since
      updated = @chat.updated_at
      travel 1.minute
      assert_not change("working")
      assert_equal [ since, updated, 1 ], [ @chat.work_status_since, @chat.updated_at, @chat.work_status_revision ]
      change("idle")
      assert_equal "idle", @chat.work_status
      change(nil)
      assert_nil @chat.work_status_since
      assert_nil @chat.work_status
      assert_equal 3, @chat.work_status_revision
    end
  end

  test "validation is strict and stale identical payloads conflict" do
    assert_raises(Chat::WorkStatus::Invalid) { change("needs_input") }
    assert_raises(Chat::WorkStatus::Invalid) { change("blocked", " ") }
    assert_raises(Chat::WorkStatus::Invalid) { change("working", "x" * 1001) }
    assert_raises(Chat::WorkStatus::Invalid) { change("working", "nul\0") }
    change("blocked", "Waiting for access")
    assert_raises(Chat::WorkStatus::Conflict) do
      @chat.with_work_status_authority!(agent: @agent) do
        @chat.change_work_status!(state: "blocked", reason: "Waiting for access", expected_revision: 0)
      end
    end
    assert_equal 1, @chat.reload.work_status_revision
  end

  test "human replied derives only from kept attributed user messages after since and resolves nothing" do
    travel_to Time.current.change(usec: 0) do
      @chat.messages.create!(role: "user", user: users(:user_1), content: "Before")
      change("needs_input", "Which option?")
      @chat.messages.create!(role: "user", user: users(:user_1), content: "Same instant")
      travel 1.second
      @chat.messages.create!(role: "assistant", agent: @agent, content: "Resident")
      @chat.messages.create!(role: "user", content: "System notice")
      discarded = @chat.messages.create!(role: "user", user: users(:user_1), content: "Removed")
      discarded.discard!
      assert_nil @chat.reload.work_status_json[:human_replied_since]
      reply = @chat.messages.create!(role: "user", user: users(:user_1), content: "Option A")
      assert_equal reply.created_at.iso8601(6), @chat.reload.work_status_json[:human_replied_since]
      assert_equal [ @chat.id ], Chat.where(id: @chat.id).work_replied.pluck(:id)
      assert_equal "needs_input", @chat.work_status
      change("working")
      assert_nil @chat.work_status_json[:human_replied_since]
      assert_empty Chat.where(id: @chat.id).work_replied
    end
  end

  test "list replies are one aggregate not one query per chat" do
    change("blocked", "Access")
    other = @chat.account.chats.create!(model_id: "openrouter/auto", work_status: "needs_input",
      work_status_reason: "Choice", work_status_since: 1.minute.ago)
    rows = Chat.where(id: [ @chat.id, other.id ]).to_a
    statements = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      statements << payload[:sql] if payload[:sql].include?("MAX(")
    end
    Chat.preload_work_status_replies(rows)
    rows.each(&:work_status_json)
    assert_equal 1, statements.size
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  test "completed preserves tag and pins but overrides hiding without archiving or recency changes" do
    tag = @chat.account.visual_tags.create!(label: "Done", icon: "Check", colour: "green", hides_from_list: true)
    @chat.update!(visual_tag: tag, last_message_at: 2.days.ago)
    activity = @chat.activity_at
    assert_includes Chat.hidden_from_list, @chat
    change("completed")
    assert_equal tag, @chat.visual_tag
    assert_includes Chat.not_hidden_from_list, @chat
    assert_not_includes Chat.hidden_from_list, @chat
    assert @chat.respondable?
    assert_not @chat.archived?
    assert_equal activity, @chat.reload.activity_at
    change(nil)
    assert_includes Chat.hidden_from_list, @chat
  end

  test "work reporting neither dismisses reply expectations nor completes a runtime" do
    message = @chat.messages.create!(role: "assistant", agent: @agent, content: "Can you choose?")
    expectation = ReplyExpectation.create!(message: message, user: users(:user_1), score: 1, classifier_version: "test")
    change("completed")
    assert expectation.reload.state_open?
    change("working")
    AgentRuntimeInteraction.record_trigger!(agent: @agent, chat: @chat, trigger_kind: "conversation",
      conversation_id: @chat.to_param, requested_by: "test", session_id: "work-test",
      endpoint_url: "https://agent.example.com", request_text: "Respond") do
      { status: 200, body: { "status" => "ok", "returncode" => 0 } }
    end
    assert_equal "working", @chat.reload.work_status
    assert_equal 2, @chat.work_status_revision
  end

  test "a seat removed after loading the conversation has no authority" do
    @chat.chat_agents.find_by!(agent: @agent).destroy!
    assert_raises(ActiveRecord::RecordNotFound) { change("working") }
    assert_nil @chat.reload.work_status
  end

  test "cached sidebar reply evidence refreshes when the human message is edited or discarded" do
    travel_to Time.current.change(usec: 0) do
      change("needs_input", "Which option?")
      travel 1.second
      reply = @chat.messages.create!(role: "user", user: users(:user_1), content: "Option A")
      Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
        payload = -> { Chat.cached_json_for(Chat.where(id: @chat.id).to_a, as: :sidebar_json).sole["work_status"] }
        assert payload.call[:human_replied_since]
        travel 1.second
        reply.update!(user: nil)
        assert_nil payload.call[:human_replied_since]
        travel 1.second
        reply.update!(user: users(:user_1))
        assert payload.call[:human_replied_since]
        travel 1.second
        reply.discard!
        assert_nil payload.call[:human_replied_since]
      end
    end
  end

  private

  def change(state, reason = nil)
    @chat.with_work_status_authority!(agent: @agent) do
      @chat.change_work_status!(state: state, reason: reason, expected_revision: @chat.work_status_revision)
    end
  end

end
