require "test_helper"

class Chats::WorkStatusesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:existing_user)
    @account = accounts(:team_account)
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Work")
    sign_in @user
  end

  test "ordinary confirmed member writes metadata and can stop tracking" do
    patch account_chat_work_status_path(@account, @chat),
      params: { state: "idle", expected_revision: 0 }, as: :json
    assert_response :ok
    assert_equal "idle", @chat.reload.work_status
    patch account_chat_work_status_path(@account, @chat),
      params: { state: nil, expected_revision: 1 }, as: :json
    assert_response :ok
    assert_nil @chat.reload.work_status
  end

  test "site admin without membership does not get a write shortcut" do
    @user.update!(is_site_admin: true)
    @user.memberships.where(account: @account).delete_all
    patch account_chat_work_status_path(@account, @chat),
      params: { state: "completed", expected_revision: 0 }, as: :json
    assert_response :not_found
    assert_nil @chat.reload.work_status
  end

  test "sidebar status and replied filters compose and tracked Done rows stay visible" do
    tag = @account.visual_tags.create!(label: "Done", icon: "Check", colour: "green", hides_from_list: true)
    @chat.update!(visual_tag: tag, work_status: "completed", work_status_since: 1.hour.ago)
    waiting = @account.chats.create!(model_id: "openrouter/auto", title: "Waiting", work_status: "blocked",
      work_status_reason: "Access", work_status_since: 1.hour.ago)
    waiting.messages.create!(role: "user", user: @user, content: "Granted")
    untracked = @account.chats.create!(model_id: "openrouter/auto", title: "Untracked")

    assert_includes sidebar_ids, @chat.to_param
    assert_equal [ @chat.to_param ], sidebar_ids(work_status: "completed")
    assert_equal [ waiting.to_param ], sidebar_ids(work_status: "blocked", work_replied: "true")
    assert_includes sidebar_ids(work_status: "untracked"), untracked.to_param
    assert_not_includes sidebar_ids(work_status: "untracked"), waiting.to_param
  end

  private

  def sidebar_ids(**filters)
    get account_chats_path(@account), params: filters,
      headers: { "X-Inertia" => "true", "X-Inertia-Version" => InertiaRails.configuration.version }
    assert_response :ok
    response.parsed_body.fetch("props").fetch("chats").map { |chat| chat["id"] }
  end

end
