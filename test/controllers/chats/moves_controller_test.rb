require "test_helper"

class Chats::MovesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    @life = @account.rooms.create!(name: "Life")
    @chat_a = @account.chats.create!(title: "A", model_id: "openrouter/auto")
    @chat_b = @account.chats.create!(title: "B", model_id: "openrouter/auto", room: @life)
    sign_in @user
  end

  test "bulk move sends selected chats to a room" do
    post move_account_chats_path(@account), params: { chat_ids: [ @chat_a.to_param ], room_id: @life.to_param }
    assert_redirected_to account_chats_path(@account)
    assert_equal @life, @chat_a.reload.room
  end

  test "a null room_id moves chats back to Main" do
    post move_account_chats_path(@account), params: { chat_ids: [ @chat_b.to_param ], room_id: nil }, as: :json
    assert_redirected_to account_chats_path(@account)
    assert_nil @chat_b.reload.room
  end

  test "chats from another account are neither found nor moved" do
    foreign_chat = accounts(:other).chats.create!(title: "Foreign", model_id: "openrouter/auto")

    post move_account_chats_path(@account), params: { chat_ids: [ foreign_chat.to_param ], room_id: @life.to_param }
    assert_redirected_to account_chats_path(@account)
    assert_nil foreign_chat.reload.room
  end

  test "a selection that cannot be moved in full moves nothing and says so" do
    foreign_chat = accounts(:other).chats.create!(title: "Foreign", model_id: "openrouter/auto")
    deleted_chat = @account.chats.create!(title: "Deleted", model_id: "openrouter/auto")
    deleted_chat.discard!

    [ foreign_chat, deleted_chat ].each do |unmovable|
      post move_account_chats_path(@account),
        params: { chat_ids: [ @chat_a.to_param, unmovable.to_param ], room_id: @life.to_param }

      assert_redirected_to account_chats_path(@account)
      follow_redirect!
      assert_nil @chat_a.reload.room
      assert_nil unmovable.reload.room
    end
  end

  test "malformed chat_ids are refused without moving anything" do
    referer = account_chats_url(@account)
    [ [], "x", nil, Array.new(501) { @chat_a.to_param }, [ 1 ], [ nil ] ].each do |ids|
      post move_account_chats_path(@account), params: { chat_ids: ids, room_id: @life.to_param },
        headers: { "HTTP_REFERER" => referer }, as: :json
      assert_redirected_to referer
    end
    assert_nil @chat_a.reload.room
  end

  test "concurrent room deletion is reported as a retryable selection error" do
    Room.stub(:resolve_for, ->(*) { raise ActiveRecord::InvalidForeignKey }) do
      post move_account_chats_path(@account), params: { chat_ids: [ @chat_a.to_param ], room_id: @life.to_param }, as: :json
    end
    assert_redirected_to account_chats_path(@account)
    follow_redirect!
    assert_match "no longer available", inertia_shared_props.fetch("errors").fetch("room_id")
  end

  test "nonmember and anonymous requests are refused" do
    post move_account_chats_path(accounts(:other)), params: { chat_ids: [ @chat_a.to_param ], room_id: nil }
    assert_response :not_found
    delete logout_path
    post move_account_chats_path(@account), params: { chat_ids: [ @chat_a.to_param ], room_id: nil }
    assert_redirected_to login_path
  end

end
