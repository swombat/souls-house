require "test_helper"

class WhiteboardsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @whiteboard = @account.whiteboards.create!(
      name: "Test Whiteboard",
      summary: "A test whiteboard",
      content: "# Test Content\n\nThis is test content."
    )

    # Enable agents feature (required for whiteboard controller)
    Setting.instance.update!(allow_agents: true)

    # Sign in user
    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "old whiteboards index redirects to the notes tab of the Field" do
    get account_whiteboards_path(@account)
    assert_redirected_to account_field_path(@account, tab: "notes")
  end

  test "old whiteboard links keep pointing at the same note" do
    get account_whiteboards_path(@account, id: @whiteboard.id)
    assert_redirected_to account_field_path(@account, tab: "notes", item: "note-#{@whiteboard.to_param}")
  end

  test "a human can create a note from the web" do
    assert_difference -> { @account.whiteboards.count }, 1 do
      post account_whiteboards_path(@account), params: { whiteboard: { name: "Week notes", content: "Hello" } }
    end
    note = @account.whiteboards.order(:id).last
    assert_equal @user, note.last_edited_by
    assert_redirected_to account_field_path(@account, tab: "notes", item: "note-#{note.to_param}")
  end

  test "creating a note without a name does not save" do
    assert_no_difference -> { @account.whiteboards.count } do
      post account_whiteboards_path(@account), params: { whiteboard: { name: "", content: "Hello" } }
    end
    assert_redirected_to account_field_path(@account, tab: "notes")
  end

  test "deleting a note soft-deletes it" do
    delete account_whiteboard_path(@account, @whiteboard)
    assert @whiteboard.reload.deleted?
    assert_redirected_to account_field_path(@account, tab: "notes")
  end

  test "should update whiteboard content" do
    new_content = "# Updated Content\n\nThis has been updated."
    initial_revision = @whiteboard.revision

    patch account_whiteboard_path(@account, @whiteboard),
      params: {
        whiteboard: { content: new_content },
        expected_revision: @whiteboard.revision
      },
      as: :json

    assert_response :success
    @whiteboard.reload
    assert_equal new_content, @whiteboard.content
    assert_equal initial_revision + 1, @whiteboard.revision
  end

  test "should return conflict when revision mismatch" do
    initial_revision = @whiteboard.revision

    # Update the whiteboard to increment revision
    @whiteboard.update!(content: "Changed by someone else")

    # Try to update with old revision
    patch account_whiteboard_path(@account, @whiteboard),
      params: {
        whiteboard: { content: "My changes" },
        expected_revision: initial_revision  # Old revision
      },
      as: :json

    assert_response :conflict
    json_response = JSON.parse(response.body)
    assert_equal "conflict", json_response["error"]
    assert_equal "Changed by someone else", json_response["current_content"]
    assert_equal initial_revision + 1, json_response["current_revision"]
  end

  test "should update last_edited_by on save" do
    patch account_whiteboard_path(@account, @whiteboard),
      params: {
        whiteboard: { content: "New content" },
        expected_revision: @whiteboard.revision
      },
      as: :json

    assert_response :success
    @whiteboard.reload
    assert_equal @user, @whiteboard.last_edited_by
  end

  test "should scope whiteboards to current account" do
    # Create a separate user and account
    other_user = User.create!(email_address: "other@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_whiteboard = other_account.whiteboards.create!(
      name: "Other Whiteboard",
      content: "Other content"
    )

    # Should not be able to access other account's whiteboard
    patch account_whiteboard_path(@account, other_whiteboard),
      params: { whiteboard: { content: "Hacked!" } },
      as: :json

    # Should get 404 since whiteboard not found in current account
    assert_response :not_found
  end

  test "should not allow updating deleted whiteboards" do
    @whiteboard.soft_delete!

    patch account_whiteboard_path(@account, @whiteboard),
      params: { whiteboard: { content: "New content" } },
      as: :json

    # Should get 404 since whiteboard is deleted (filtered by .active scope)
    assert_response :not_found
  end

end
