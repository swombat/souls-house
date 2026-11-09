require "test_helper"

class Accounts::ConversationTitlesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @account = accounts(:personal_account)
    sign_in users(:user_1)
    @chat = @account.chats.create!(title: "Build: conversation links", model_id: "openrouter/auto")
  end

  def titles(ids, account: @account)
    get account_conversation_titles_path(account, ids: Array(ids).join(",")), as: :json
    assert_response :success
    response.parsed_body["titles"]
  end

  test "a conversation in the reader's account answers with its current title" do
    assert_equal({ @chat.to_param => "Build: conversation links" }, titles(@chat.to_param))

    @chat.update!(title: "Renamed")
    assert_equal({ @chat.to_param => "Renamed" }, titles(@chat.to_param))
  end

  test "an untitled conversation answers with the default title" do
    untitled = @account.chats.create!(model_id: "openrouter/auto")
    untitled.update_column(:title, nil)

    assert_equal({ untitled.to_param => "New Conversation" }, titles(untitled.to_param))
  end

  test "another account's conversation stays absent, even one the reader can open there" do
    foreign = accounts(:another_team).chats.create!(title: "Not yours", model_id: "openrouter/auto")
    own_elsewhere = accounts(:team_account).chats.create!(title: "Yours, but not here", model_id: "openrouter/auto")

    assert_equal({}, titles([ foreign.to_param, own_elsewhere.to_param ]))
  end

  test "a conversation a resident joined as a guest stays absent from its home account" do
    resident = agents(:research_assistant) # home: personal_account
    host = accounts(:team_account)
    host.guest_memberships.create!(agent: resident, added_by: users(:user_1))
    guest_room_chat = host.chats.create!(title: "Hosted elsewhere", model_id: "openrouter/auto", agents: [ resident ])

    assert_equal({}, titles(guest_room_chat.to_param))
    assert_equal({ guest_room_chat.to_param => "Hosted elsewhere" }, titles(guest_room_chat.to_param, account: host))
  end

  test "a discarded conversation stays absent; an archived one still answers" do
    discarded = @account.chats.create!(title: "Binned", model_id: "openrouter/auto")
    discarded.update_column(:discarded_at, Time.current)
    archived = @account.chats.create!(title: "Archived", model_id: "openrouter/auto")
    archived.update_column(:archived_at, Time.current)

    assert_equal({ archived.to_param => "Archived" }, titles([ discarded.to_param, archived.to_param ]))
  end

  test "words, numbers and malformed IDs are never looked up" do
    assert_equal({}, titles([ "iPhone", "Github", "123456", "a,b", "ab-cdE", @chat.id.to_s ]))
  end

  test "someone outside the account gets nothing" do
    sign_in users(:existing_user)
    get account_conversation_titles_path(@account, ids: @chat.to_param), as: :json

    assert_response :not_found
  end

  test "anonymous gets nothing" do
    sign_out if respond_to?(:sign_out)
    reset!
    get account_conversation_titles_path(@account, ids: @chat.to_param), as: :json

    assert_response :redirect
  end

end
