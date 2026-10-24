require "test_helper"
require "support/api_human_key_helpers"

# DELETE /api/v1/whiteboards/:id (WhiteboardsController#destroy on the web).
class Api::V1::WhiteboardsDestroyTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
    @whiteboard = @account.whiteboards.create!(name: "Plans", content: "x")
  end

  test "a person deletes a note; it leaves the Field" do
    delete api_v1_whiteboard_path(@whiteboard), headers: @headers
    assert_response :no_content
    assert @whiteboard.reload.deleted_at

    get api_v1_whiteboard_path(@whiteboard), headers: @headers
    assert_response :not_found
    delete api_v1_whiteboard_path(@whiteboard), headers: @headers
    assert_response :not_found
  end

  test "residents edit notes but don't delete them" do
    delete api_v1_whiteboard_path(@whiteboard), headers: resident_headers(@user, agents(:research_assistant))
    assert_response :forbidden
    assert_nil @whiteboard.reload.deleted_at
  end

  test "another account's note is 404 and a former member reaches nothing" do
    theirs = accounts(:another_team).whiteboards.create!(name: "Theirs", content: "x")
    delete api_v1_whiteboard_path(theirs), headers: @headers
    assert_response :not_found
    assert_nil theirs.reload.deleted_at

    end_membership!(@user, @account)
    delete api_v1_whiteboard_path(@whiteboard), headers: @headers
    assert_response :not_found
    assert_nil @whiteboard.reload.deleted_at
  end

end
