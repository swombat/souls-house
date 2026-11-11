require "test_helper"

class Accounts::NoticesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    sign_in @user
  end

  test "account member can view active account notices" do
    notice = @account.notices.create!(
      scope: "account",
      notice_type: "announcement",
      body: "Account news",
      expires_at: 1.day.from_now,
      created_by: @user
    )

    get account_notices_path(@account)

    assert_response :success
    assert_equal notice.id, inertia_shared_props.fetch("notices").first.fetch("id")
    assert_equal "Account-wide", inertia_shared_props.fetch("scope_label")
    assert_equal account_notice_path(@account, notice),
                 inertia_shared_props.fetch("notices").first.fetch("destroy_path")
  end

  test "account notice management excludes automatic model change notices" do
    agent = agents(:research_assistant)
    model_notice = @account.notices.create!(
      scope: "account",
      notice_type: "model_changed",
      params: {
        agent_id: agent.to_param,
        agent_name: agent.name,
        from: "old/model",
        to: "new/model",
        changed_at: Time.current.utc.iso8601
      },
      expires_at: 1.day.from_now
    )

    get account_notices_path(@account)

    assert_response :success
    assert_empty inertia_shared_props.fetch("notices")

    delete account_notice_path(@account, model_notice)
    assert_response :not_found
    assert model_notice.reload.expires_at.future?
  end

  test "account member can post an account notice with selected expiry" do
    travel_to Time.zone.local(2026, 8, 1, 12) do
      assert_difference "Notice.count", 1 do
        post account_notices_path(@account), params: {
          notice: { body: "We are travelling.", expires_in_days: "14" }
        }
      end
    end

    notice = Notice.last
    assert_equal "account", notice.scope
    assert_equal @account, notice.account
    assert_equal @user, notice.created_by
    assert_equal "We are travelling.", notice.body
    assert_equal Time.zone.local(2026, 8, 15, 12), notice.expires_at
  end

  test "an expiry outside the offered choices falls back to the default week" do
    travel_to Time.zone.local(2026, 8, 1, 12) do
      post account_notices_path(@account), params: {
        notice: { body: "Forever, please.", expires_in_days: "365" }
      }
    end

    assert_equal Time.zone.local(2026, 8, 8, 12), Notice.last.expires_at
  end

  test "blank account notice is rejected" do
    assert_no_difference "Notice.count" do
      post account_notices_path(@account), params: {
        notice: { body: "", expires_in_days: "7" }
      }
    end

    assert_redirected_to account_notices_path(@account)
  end

  test "account member can end an active account notice" do
    notice = @account.notices.create!(
      scope: "account",
      notice_type: "announcement",
      body: "Temporary news",
      expires_at: 1.day.from_now
    )

    delete account_notice_path(@account, notice)

    assert_redirected_to account_notices_path(@account)
    assert_not_includes Notice.active, notice
    assert notice.reload.persisted?
  end

  test "notices remain scoped to the current user's accounts" do
    get account_notices_path(accounts(:other))

    assert_response :not_found
  end

end
