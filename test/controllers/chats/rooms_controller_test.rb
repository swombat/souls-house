require "test_helper"

class Chats::RoomsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    @life = @account.rooms.create!(name: "Life")
    @chat = @account.chats.create!(title: "Keep title", model_id: "openrouter/auto")
    sign_in @user
  end

  test "member moves a chat to a room and back to Main while staying on the current thread" do
    current_chat = @account.chats.create!(title: "Currently open", model_id: "openrouter/auto")
    referer = account_chat_url(@account, current_chat)
    patch account_chat_room_path(@account, @chat), params: { room_id: @life.to_param },
      headers: { "HTTP_REFERER" => referer }
    assert_redirected_to referer
    assert_equal @life, @chat.reload.room
    assert_equal "Keep title", @chat.title

    patch account_chat_room_path(@account, @chat), params: { room_id: nil }, as: :json
    assert_redirected_to account_chat_path(@account, @chat)
    assert_nil @chat.reload.room
  end

  test "missing selection is refused instead of silently clearing" do
    @chat.update!(room: @life)
    patch account_chat_room_path(@account, @chat), params: {}, as: :json
    assert_redirected_to account_chat_path(@account, @chat)
    assert_equal @life, @chat.reload.room
    follow_redirect!
    assert_match "must be provided", inertia_shared_props.fetch("errors").fetch("room_id")
  end

  test "concurrent room deletion is reported as a retryable selection error" do
    Room.stub(:resolve_for, ->(*) { raise ActiveRecord::InvalidForeignKey }) do
      patch account_chat_room_path(@account, @chat), params: { room_id: @life.to_param }, as: :json
    end
    assert_redirected_to account_chat_path(@account, @chat)
    assert_nil @chat.reload.room
    follow_redirect!
    assert_match "no longer available", inertia_shared_props.fetch("errors").fetch("room_id")
  end

  test "foreign room and foreign chat cannot be selected" do
    foreign_room = accounts(:other).rooms.create!(name: "Elsewhere")
    patch account_chat_room_path(@account, @chat), params: { room_id: foreign_room.to_param }
    assert_response :not_found
    assert_nil @chat.reload.room

    foreign_chat = accounts(:other).chats.create!(title: "Other", model_id: "openrouter/auto")
    patch account_chat_room_path(@account, foreign_chat), params: { room_id: @life.to_param }
    assert_response :not_found
  end

  test "nonmember and anonymous selection requests are refused" do
    patch account_chat_room_path(accounts(:other), @chat), params: { room_id: @life.to_param }
    assert_response :not_found
    delete logout_path
    patch account_chat_room_path(@account, @chat), params: { room_id: @life.to_param }
    assert_redirected_to login_path
  end

end
