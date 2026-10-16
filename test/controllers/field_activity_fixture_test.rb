require "test_helper"

class FieldActivityFixtureTest < ActionDispatch::IntegrationTest

  test "synthetic browser mutations use real committed producer paths" do
    account = Account.create!(name: "E2E Field activity fixture", account_type: :team)
    account.add_user!(users(:user_1), role: "owner", skip_confirmation: true)
    account.agents.create!(name: "Synthetic Field resident", runtime: "external")

    mutate(account, "chat")
    assert_equal 1, account.chats.count
    mutate(account, "arrive")
    note = response.parsed_body.fetch("note")
    assert_equal 1, account.field_songs.count
    assert_equal 1, account.field_tweets.count
    mutate(account, "rename", note: note)
    assert_equal "Changed elsewhere", account.whiteboards.find(note).content
    mutate(account, "delete", note: note)
    assert account.whiteboards.find(note).deleted?
    mutate(account, "late")
    assert account.whiteboards.active.exists?(name: "Live late arrival")
  end

  test "browser mutations refuse non-synthetic accounts" do
    post "/test/e2e/field_activity_fixture",
      params: { account_id: accounts(:personal_account).id, operation: "late" }, as: :json
    assert_response :not_found
  end

  private

  def mutate(account, operation, **extra)
    post "/test/e2e/field_activity_fixture",
      params: { account_id: account.id, operation: operation, **extra }, as: :json
    assert_response :success
  end

end
