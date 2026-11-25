require "test_helper"

class Accounts::PracticesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    sign_in @user
  end

  test "a member sees the practices with their last editor and the characters used" do
    AccountPractice.add!(account: @account, text: "Finished threads get the done tag.", by: agents(:research_assistant))

    get account_practices_path(@account), headers: { "X-Inertia" => "true", "X-Inertia-Version" => ViteRuby.digest }

    assert_response :success
    props = inertia_shared_props
    line = props.fetch("practices").sole
    assert_equal "Finished threads get the done tag.", line.fetch("text")
    assert_equal "resident", line.dig("updated_by", "kind")
    assert_equal "Finished threads get the done tag.".length, props.fetch("used")
    assert_equal 3000, props.dig("limits", "max_total")
  end

  test "a member adds, edits, moves and removes a practice" do
    post account_practices_path(@account), params: { text: "First" }
    assert_redirected_to account_practices_path(@account)
    post account_practices_path(@account), params: { text: "Second" }
    first, second = @account.account_practices.ordered.to_a
    assert_equal @user, first.updated_by_user

    patch account_practice_path(@account, first), params: { text: "First, edited" }
    assert_equal "First, edited", first.reload.text

    patch account_practice_path(@account, second), params: { position: 1 }
    assert_equal [ "Second", "First, edited" ], @account.account_practices.ordered.pluck(:text)

    delete account_practice_path(@account, second)
    assert_equal [ "First, edited" ], @account.account_practices.ordered.pluck(:text)
    assert_equal 5, AuditLog.where(account: @account, user: @user).where("action LIKE '%account_practice'").count
  end

  test "someone outside the account cannot reach its practices" do
    other = accounts(:team_account)
    AccountPractice.add!(account: other, text: "Theirs", by: users(:user_1))
    sign_in users(:confirmed_user)

    post account_practices_path(other), params: { text: "Mine now" }

    assert_includes [ 302, 404 ], response.status
    assert_equal [ "Theirs" ], other.account_practices.pluck(:text)
  end

end
