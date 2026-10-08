require "test_helper"

# Review round on the conversation-lifecycle slice (#233): every new path
# checks the person's current membership of the room's own account, message
# editing stops at deleted rooms, and the chats feature gate applies.
class Api::V1::ConversationLifecycleGuardsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Guards")
    @message = @chat.messages.create!(role: "user", user: @user, content: "Mine")
    @key = ApiKey.generate_for(@user, name: "Person's agent", account: @account)
    @headers = { "Authorization" => "Bearer #{@key.raw_token}" }
  end

  # -- 1. current membership on the new listing and update paths --------------

  def assert_reaches_nothing
    @chat.archive!
    deleted = @account.chats.create!(model_id: "openrouter/auto", title: "Gone")
    deleted.discard!

    %w[archived deleted].each do |filter|
      get api_v1_conversations_path, params: { filter: filter }, headers: @headers
      assert_response :not_found, "filter=#{filter}"
      assert_nil response.parsed_body["conversations"]
    end

    @chat.unarchive!
    patch api_v1_conversation_path(@chat), params: { web_access: true }, headers: @headers, as: :json
    assert_response :not_found
    patch api_v1_conversation_path(@chat), params: { model_id: "anthropic/claude-opus-4" }, headers: @headers, as: :json
    assert_response :not_found
    @chat.reload
    assert_not @chat.web_access
    assert_equal "openrouter/auto", @chat.model_id
  end

  test "a departed member's key cannot list archived or deleted rooms or change model and web access" do
    # The membership row goes; the key itself survives, which is the case the
    # review found.
    Membership.where(user: @user, account: @account).delete_all
    assert_reaches_nothing
  end

  test "an unconfirmed member's key reaches nothing on the new paths" do
    Membership.find_by!(user: @user, account: @account).update_columns(confirmed_at: nil)
    assert_reaches_nothing
  end

  test "a disabled account's key reaches nothing on the new paths" do
    @account.update_columns(disabled_at: Time.current)
    assert_reaches_nothing
  end

  test "a current member still lists archived and deleted rooms and changes web access" do
    @chat.archive!
    get api_v1_conversations_path, params: { filter: "archived" }, headers: @headers
    assert_response :success
    assert_includes response.parsed_body["conversations"].map { |c| c["id"] }, @chat.to_param
    patch api_v1_conversation_path(@chat), params: { web_access: true }, headers: @headers, as: :json
    assert_response :success
    assert @chat.reload.web_access
  end

  # -- an account key stays inside its own account ---------------------------

  test "a key minted for one account gets 404 on a room in another account the person also belongs to" do
    team = accounts(:team_account)
    # The person is a confirmed member (owner) of both accounts; the key is for one.
    assert Membership.confirmed.exists?(user: @user, account: team)
    room = team.chats.new(model_id: "openrouter/auto", title: "Team room", manual_responses: true)
    room.agent_ids = [ agents(:other_account_agent).id ]
    room.save!
    bare = team.chats.create!(model_id: "openrouter/auto", title: "Team bare")
    mine = room.messages.create!(role: "user", user: @user, content: "Team words")
    flagged = room.messages.create!(role: "assistant", content: "Please reply")
    room.with_lock { ReplyExpectation.record!(message: flagged, user: @user, score: 0.95) }

    [ {}, { account_id: team.to_param } ].each do |narrowing|
      requests = {
        archive: -> { post api_v1_conversation_archive_path(room, narrowing), headers: @headers, as: :json },
        discard: -> { post api_v1_conversation_discard_path(room, narrowing), headers: @headers, as: :json },
        fork: -> { post api_v1_conversation_fork_path(room, narrowing), headers: @headers, as: :json },
        assign: -> { post api_v1_conversation_agent_assignment_path(bare, narrowing), params: { agent_id: agents(:other_account_agent).to_param }, headers: @headers, as: :json },
        web_access: -> { patch api_v1_conversation_path(room, narrowing), params: { web_access: true }, headers: @headers, as: :json },
        model: -> { patch api_v1_conversation_path(room, narrowing), params: { model_id: "anthropic/claude-opus-4" }, headers: @headers, as: :json },
        edit: -> { patch api_v1_conversation_message_path(room, mine, narrowing), params: { content: "Changed" }, headers: @headers, as: :json },
        delete: -> { delete api_v1_conversation_message_path(room, mine, narrowing), headers: @headers, as: :json },
        dismiss: -> { post api_v1_conversation_reply_dismissal_path(room, narrowing), params: { message_id: flagged.to_param }, headers: @headers, as: :json },
        reset: -> { post api_v1_conversation_message_safeguard_reset_path(room, flagged, narrowing), headers: @headers, as: :json }
      }
      assert_no_difference [ -> { Chat.with_discarded.count }, -> { AuditLog.count }, -> { Message.count } ] do
        requests.each do |name, request|
          request.call
          assert_response :not_found, "#{name} #{narrowing}"
        end
      end
    end

    room.archive!
    get api_v1_conversations_path, params: { filter: "archived" }, headers: @headers
    assert_response :success
    assert_not_includes response.parsed_body["conversations"].map { |c| c["id"] }, room.to_param
    room.unarchive!

    room.reload
    assert_not room.discarded?
    assert_not room.web_access
    assert_equal "openrouter/auto", room.model_id
    assert_not bare.reload.manual_responses?
    assert_equal "Team words", mine.reload.content
    assert_not mine.discarded?
  end

  # -- 2. message editing stops at deleted rooms ------------------------------

  test "editing a message in a deleted conversation is 404 and changes nothing" do
    @chat.discard!
    before = @message.revision
    patch api_v1_conversation_message_path(@chat, @message), params: { content: "Rewritten" }, headers: @headers, as: :json
    assert_response :not_found
    assert_nil response.parsed_body["message"]
    @message.reload
    assert_equal "Mine", @message.content
    assert_equal before, @message.revision
    assert_not AuditLog.exists?(action: "update_message", auditable: @message)
  end

  test "the author can still delete a message in a deleted conversation, and repeat it" do
    @chat.discard!
    assert_difference -> { AuditLog.where(action: "delete_message", auditable: @message).count }, 1 do
      2.times do
        delete api_v1_conversation_message_path(@chat, @message), headers: @headers, as: :json
        assert_response :success
        assert response.parsed_body.dig("message", "discarded")
      end
    end
    assert @message.reload.discarded?
  end

  # -- 3. the chats feature gate ----------------------------------------------

  test "with chats switched off, every new conversation action is refused and nothing changes" do
    agent = agents(:research_assistant)
    flagged = @chat.messages.create!(role: "assistant", content: "Please reply")
    @chat.with_lock { ReplyExpectation.record!(message: flagged, user: @user, score: 0.95) }
    expectation_state = ReplyExpectation.find_by(message: flagged, user: @user)&.state
    Setting.instance.update!(allow_chats: false)

    requests = [
      -> { post api_v1_conversation_archive_path(@chat), headers: @headers, as: :json },
      -> { delete api_v1_conversation_archive_path(@chat), headers: @headers, as: :json },
      -> { post api_v1_conversation_discard_path(@chat), headers: @headers, as: :json },
      -> { delete api_v1_conversation_discard_path(@chat), headers: @headers, as: :json },
      -> { post api_v1_conversation_fork_path(@chat), headers: @headers, as: :json },
      -> { post api_v1_conversation_agent_assignment_path(@chat), params: { agent_id: agent.to_param }, headers: @headers, as: :json },
      -> { post api_v1_conversation_reply_dismissal_path(@chat), params: { message_id: flagged.to_param }, headers: @headers, as: :json },
      -> { get api_v1_reply_attention_path, headers: @headers },
      -> { post api_v1_conversation_message_safeguard_reset_path(@chat, flagged), headers: @headers, as: :json },
      -> { patch api_v1_conversation_message_path(@chat, @message), params: { content: "Edited" }, headers: @headers, as: :json },
      -> { delete api_v1_conversation_message_path(@chat, @message), headers: @headers, as: :json },
      -> { patch api_v1_conversation_path(@chat), params: { web_access: true }, headers: @headers, as: :json },
      -> { patch api_v1_conversation_path(@chat), params: { model_id: "anthropic/claude-opus-4" }, headers: @headers, as: :json },
      -> { get api_v1_conversations_path, params: { filter: "archived" }, headers: @headers },
      -> { get api_v1_conversations_path, params: { filter: "deleted" }, headers: @headers }
    ]

    assert_no_difference [ -> { Chat.with_discarded.count }, -> { AuditLog.count }, -> { Message.count } ] do
      requests.each_with_index do |request, index|
        request.call
        assert_response :forbidden, "request #{index}"
        assert_equal "feature_disabled", response.parsed_body["code"], "request #{index}"
      end
    end
    @chat.reload
    assert_not @chat.archived?
    assert_not @chat.discarded?
    assert_not @chat.manual_responses?
    assert_not @chat.web_access
    assert_equal "Mine", @message.reload.content
    assert_not @message.discarded?
    assert_equal expectation_state, ReplyExpectation.find_by(message: flagged, user: @user)&.state
  end

end
