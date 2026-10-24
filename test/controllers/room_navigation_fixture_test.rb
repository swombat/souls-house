require "test_helper"

class RoomNavigationFixtureTest < ActionDispatch::IntegrationTest

  test "synthetic room mutations exercise the model lifecycle and reorder producer" do
    account = Account.create!(name: "E2E Room navigation fixture", account_type: :team)
    mutate(account, "create", name: "First")
    first = response.parsed_body.fetch("id")
    mutate(account, "create", name: "Second")
    second = response.parsed_body.fetch("id")
    mutate(account, "move", room: second, direction: -1)
    assert_equal [ second, first ], account.rooms.reload.map(&:to_param)
    mutate(account, "rename", room: first, name: "Renamed")
    assert_equal "Renamed", account.rooms.find(first).name
    mutate(account, "delete", room: first)
    assert_not account.rooms.exists?(id: Room.decode_id(first))
  end

  test "browser room mutations refuse non-synthetic accounts" do
    post "/test/e2e/room_navigation_fixture",
      params: { account_id: accounts(:personal_account).id, operation: "create", name: "Forbidden" }, as: :json
    assert_response :not_found
  end

  private

  def mutate(account, operation, **extra)
    post "/test/e2e/room_navigation_fixture",
      params: { account_id: account.id, operation: operation, **extra }, as: :json
    assert_response :success
  end

end
