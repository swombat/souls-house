require "test_helper"

class Api::V1::HumanMentionsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:confirmed_user)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @mira = @account.agents.create!(name: "Mira", system_prompt: "Test", runtime: "external")
    @lume = @account.agents.create!(name: "Lume", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.create!(title: "Human tags", manual_responses: true, agents: [ @mira, @lume ])
    key = ApiKey.generate_for(@user, name: "Human tags")
    @headers = { "Authorization" => "Bearer #{key.raw_token}" }
  end

  test "human mentions accept durable requests without claiming invocation delivery" do
    live do
      assert_enqueued_jobs 1, only: MessageDispatchJob do
        assert_difference "Message.count", 1 do
          send_message("@Mira then @Lume")
        end
      end
    end
    assert_response :created
    assert_equal [ @mira.id, @lume.id ], @chat.messages.last.message_dispatch.target_agent_ids
    assert_equal [ receipt(@mira, "queued"), receipt(@lume, "queued") ], response.parsed_body["handoffs"]
    assert_not response.parsed_body["ai_response_triggered"]
    assert_equal 0, @chat.agent_runtime_interactions.count
  end

  test "a busy mention has a durable held receipt" do
    live do
      AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat)
      send_message("@Mira when you are free")
    end
    assert_response :created
    message = @chat.messages.last
    assert_nil message.message_dispatch
    assert PendingWakeSource.exists?(message: message)
    assert_equal [ receipt(@mira, "held") ], response.parsed_body["handoffs"]
  end

  test "human acceptance has no controller-built orphan in the chat association" do
    factory = Messages::PostFromHuman.method(:new)
    checked_factory = ->(**arguments) do
      assert_empty arguments.fetch(:chat).association(:messages).target.select(&:new_record?)
      factory.call(**arguments)
    end
    live do
      Messages::PostFromHuman.stub(:new, checked_factory) do
        assert_difference "Message.count", 1 do
          send_message("@Mira only one message")
        end
      end
    end
    assert_response :created
  end

  test "no mention and a nonmember tag create no requests or receipts" do
    live do
      [ "Hello everyone", "@Absent please look" ].each do |content|
        assert_no_difference [ "MessageDispatch.count", "PendingWake.count" ] do
          send_message(content)
        end
        assert_response :created
        assert_equal [], response.parsed_body["handoffs"]
      end
    end
  end

  test "a sole resident explicitly tagged is reserved once with no mention receipt" do
    @chat.agents = [ @mira ]
    live do
      assert_difference "AgentRuntimeInteraction.count", 1 do
        assert_no_enqueued_jobs only: MessageDispatchJob do
          send_message("@Mira hello")
        end
      end
    end
    assert_response :created
    assert_equal "automatic", @chat.messages.last.message_dispatch.kind
    assert response.parsed_body["ai_response_triggered"]
    assert_equal [], response.parsed_body["handoffs"]
  end

  test "live activity off refuses a mention without clearing its draft or writing a message" do
    draft = ConversationDraft.for(chat: @chat, user: @user)
    draft.replace!(content: "@Mira hello", revision: 0)
    AgentRuntimeInteraction.stub(:live_activity_enabled?, false) do
      assert_no_difference [ "Message.count", "MessageDispatch.count", "PendingWake.count" ] do
        send_message("@Mira hello", draft_revision: 1)
      end
    end
    assert_response :service_unavailable
    assert response.parsed_body["retryable"]
    assert_equal [ "@Mira hello", 1 ], [ draft.reload.content, draft.revision ]
  end

  test "draft conflict rolls back and matching revision clears with the dispatch" do
    draft = ConversationDraft.for(chat: @chat, user: @user)
    draft.replace!(content: "@Mira draft", revision: 0)
    live do
      assert_no_difference [ "Message.count", "MessageDispatch.count" ] do
        send_message("@Mira draft", draft_revision: 0)
      end
      assert_response :conflict
      send_message("@Mira draft", draft_revision: 1)
    end
    assert_response :created
    assert_equal({ "content" => "", "revision" => 2 }, response.parsed_body["draft"])
    assert_equal "", draft.reload.content
  end

  test "an enqueue failure after commit is accepted with its durable queued receipt" do
    live do
      MessageDispatchJob.stub(:perform_later, ->(*) { raise "queue down" }) do
        send_message("@Mira accepted")
      end
    end
    assert_response :created
    assert_equal "pending", @chat.messages.last.message_dispatch.status
    assert_equal [ receipt(@mira, "queued") ], response.parsed_body["handoffs"]
  end

  test "human files and pinned stones survive shared acceptance" do
    stone = Stone.publish!(chat: @chat, title: "Reference", html: "<!doctype html><html><body>Reference</body></html>", author: @mira, public: true)
    live do
      assert_difference [ "Message.count", "MessageStoneRevision.count" ], 1 do
        post api_v1_conversation_messages_url(@chat),
          params: { content: "@Mira reference", files: [ fixture_file_upload("test_image.png", "image/png") ],
                    stone_revision_ids: [ stone.latest_revision.to_param ] }, headers: @headers
      end
    end
    assert_response :created
    message = @chat.messages.last
    assert_equal "test_image.png", message.attachments.sole.filename.to_s
    assert_equal [ stone.latest_revision ], message.stone_revisions.to_a
    assert_equal [ receipt(@mira, "queued") ], response.parsed_body["handoffs"]
  end

  test "human runtime run association is forbidden before acceptance" do
    assert_no_difference [ "Message.count", "MessageDispatch.count" ] do
      send_message("@Mira hello", runtime_run_id: "not-a-human-run")
    end
    assert_response :forbidden
  end

  test "human attachment-only messages use shared file acceptance" do
    post api_v1_conversation_messages_url(@chat),
      params: { files: [ fixture_file_upload("test_image.png", "image/png") ] }, headers: @headers
    assert_response :created
    assert @chat.messages.last.attachments.attached?
    assert_equal [], response.parsed_body["handoffs"]
  end

  test "invalid human stone references are refused before any request is accepted" do
    other = @account.chats.create!(title: "Other room", agents: [ @mira ])
    stone = Stone.publish!(chat: other, title: "Private reference", html: "<!doctype html><html><body>Reference</body></html>", author: @mira, public: true)
    assert_no_difference [ "Message.count", "MessageDispatch.count", "MessageStoneRevision.count" ] do
      send_message("@Mira reference", stone_revision_ids: [ stone.latest_revision.to_param ])
    end
    assert_response :not_found
    assert_no_difference "Message.count" do
      send_message("@Mira malformed", stone_revision_ids: "not-an-array")
    end
    assert_response :unprocessable_entity
  end

  test "receipt projection reads blocked and expired requests without driving them" do
    live { send_message("@Mira acceptance") }
    message = @chat.messages.last
    dispatch = message.message_dispatch
    dispatch.update!(status: "cancelled", reason: "target_busy")
    assert_no_enqueued_jobs do
      assert_equal [ receipt(@mira, "blocked", "target_busy").symbolize_keys ],
        Messages::HumanMentionReceipts.new(message, sole_resident: false).call
    end
    dispatch.update!(status: "pending", reason: nil, expires_at: 1.second.ago)
    assert_no_enqueued_jobs do
      assert_equal [ receipt(@mira, "blocked", "not_started_in_time").symbolize_keys ],
        Messages::HumanMentionReceipts.new(message, sole_resident: false).call
    end
    assert_equal "pending", dispatch.reload.status
    dispatch.update!(status: "expired", reason: "not_started_in_time")
    assert_equal [ receipt(@mira, "blocked", "not_started_in_time").symbolize_keys ],
      Messages::HumanMentionReceipts.new(message, sole_resident: false).call
  end

  test "a partially reserved dispatch only reports the target with a durable run as queued" do
    live { send_message("@Mira and @Lume please") }
    message = @chat.messages.last
    dispatch = message.message_dispatch
    live do
      run = AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat, message_dispatch: dispatch)
      dispatch.update!(status: "reserved", runtime_interaction: run)
    end
    assert_no_enqueued_jobs do
      assert_equal [
        receipt(@mira, "queued").symbolize_keys,
        receipt(@lume, "blocked", "target_not_reserved").symbolize_keys
      ], Messages::HumanMentionReceipts.new(message, sole_resident: false).call
    end
  end

  test "duplicate-name matching stays identical to direct shared human acceptance" do
    # Account names are case-sensitive, while human mentions are not.
    # Both entry points select the lowest-ID namesake and project one receipt.
    duplicate = @account.agents.create!(name: "MIRA", system_prompt: "Test", runtime: "external")
    @chat.agents << duplicate
    direct = nil
    live do
      direct = Messages::PostFromHuman.new(chat: @chat, user: @user, content: "@Mira direct").call
      send_message("@Mira API")
    end
    assert_response :created
    assert_operator @mira.id, :<, duplicate.id
    expected = [ @mira.id ]
    assert_equal expected, direct.message.message_dispatch.target_agent_ids.sort
    assert_equal direct.message.message_dispatch.target_agent_ids.sort, @chat.messages.last.message_dispatch.target_agent_ids.sort
    assert_equal [ @mira.to_param ], response.parsed_body["handoffs"].map { |r| r["recipient_id"] }
  end

  test "receipt projection uses the acceptance roster decision after seats change" do
    result = nil
    live do
      result = Messages::PostFromHuman.new(chat: @chat, user: @user, content: "@Mira before departure").call
    end
    assert_not result.sole_resident
    @chat.agents = [ @mira ]
    assert_equal [ receipt(@mira, "queued").symbolize_keys ],
      Messages::HumanMentionReceipts.new(result.message, sole_resident: result.sole_resident).call

    live do
      AgentRuntimeInteraction.reserve!(agent: @mira, chat: @chat)
      result = Messages::PostFromHuman.new(chat: @chat, user: @user, content: "Busy sole-resident message").call
    end
    assert result.sole_resident
    assert PendingWakeSource.exists?(message: result.message)
    @chat.agents << @lume
    assert_equal [], Messages::HumanMentionReceipts.new(result.message, sole_resident: result.sole_resident).call
  end

  private

  def send_message(content, **params)
    post api_v1_conversation_messages_url(@chat), params: { content: content }.merge(params), headers: @headers, as: :json
  end

  def receipt(agent, state, reason = nil)
    { "recipient_id" => agent.to_param, "recipient_name" => agent.name, "source" => "tag", "state" => state, "reason" => reason }
  end

  def live(&block)
    AgentRuntimeInteraction.stub(:live_activity_enabled?, true, &block)
  end

end
