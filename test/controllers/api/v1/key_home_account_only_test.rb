require "test_helper"
require "support/api_human_key_helpers"

# A key acts only in its own account on the Field files, recordings and
# whiteboard endpoints. Naming any other account_id is 404 and changes nothing.
# Before this, these endpoints ignored account_id and quietly used the key's
# account, so a request aimed at B read or changed A.
class Api::V1::KeyHomeAccountOnlyTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:existing_user)
    @a = accounts(:existing_user_account)
    @b = accounts(:team_account)
    @key = human_headers(@user, @a)
    @to_b = { account_id: @b.to_param }
    @board = @a.whiteboards.create!(name: "A board", content: "a")

    @resident = agents(:research_assistant)
    @resident_key = resident_headers(users(:user_1), @resident)
  end

  test "a person's key naming another account is refused on reads" do
    get api_v1_whiteboards_path(@to_b), headers: @key
    assert_response :not_found
    get api_v1_whiteboard_path(@board, @to_b), headers: @key
    assert_response :not_found
    get api_v1_whiteboard_versions_path(@board, @to_b), headers: @key
    assert_response :not_found
    get api_v1_field_files_path(@to_b), headers: @key
    assert_response :not_found
    get api_v1_field_recordings_path(@to_b), headers: @key
    assert_response :not_found
  end

  test "a person's key naming another account creates and changes nothing" do
    assert_no_difference -> { Whiteboard.count } do
      post api_v1_whiteboards_path(@to_b), params: { name: "Meant for B", content: "b" }, headers: @key, as: :json
      assert_response :not_found
    end

    patch api_v1_whiteboard_path(@board, @to_b), params: { content: "changed", lock_version: @board.lock_version }, headers: @key, as: :json
    assert_response :not_found
    assert_equal "a", @board.reload.content
  end

  test "the key's own account, named or not, still works" do
    get api_v1_whiteboards_path(account_id: @a.to_param), headers: @key
    assert_response :success
    get api_v1_whiteboards_path, headers: @key
    assert_response :success

    post api_v1_whiteboards_path(account_id: @a.to_param), params: { name: "Mine", content: "x" }, headers: @key, as: :json
    assert_response :created
    assert_equal @a, Whiteboard.find_by!(name: "Mine").account
  end

  test "malformed account_id is refused" do
    get api_v1_whiteboards_path(account_id: "not-an-id"), headers: @key
    assert_response :not_found
    # An array was already refused by the foundation (#232), before any lookup.
    get api_v1_whiteboards_path, params: { account_id: [ @a.to_param ] }, headers: @key
    assert_response :unprocessable_entity
  end

  test "a resident key naming another account is refused, and its own Field still works" do
    other = accounts(:another_team)
    get api_v1_field_files_path(account_id: other.to_param), headers: @resident_key
    assert_response :not_found
    get api_v1_field_recordings_path(account_id: other.to_param), headers: @resident_key
    assert_response :not_found
    get api_v1_whiteboards_path(account_id: other.to_param), headers: @resident_key
    assert_response :not_found

    get api_v1_field_files_path(account_id: @resident.account.to_param), headers: @resident_key
    assert_response :success
    get api_v1_whiteboards_path, headers: @resident_key
    assert_response :success
  end

end
