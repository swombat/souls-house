require "test_helper"

class Chats::DiscardsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @team_account = accounts(:team_account)
    @member = users(:existing_user)
    @team_chat = @team_account.chats.create!(model_id: "openrouter/auto", title: "Team Chat")

    post login_path, params: { email_address: @member.email_address, password: "password123" }
    assert_redirected_to root_path
  end

  # require_admin is manageable_by?, which any confirmed member passes; site
  # admins and non-members never reach a different branch through this route.
  test "a confirmed member discards and restores a chat, and both are audited" do
    assert_difference "AuditLog.count", 1 do
      post account_chat_discard_path(@team_account, @team_chat)
    end
    assert_redirected_to account_chats_path(@team_account)
    assert @team_chat.reload.discarded?
    assert_equal [ "discard_chat", @team_chat ], [ AuditLog.last.action, AuditLog.last.auditable ]

    assert_difference "AuditLog.count", 1 do
      delete account_chat_discard_path(@team_account, @team_chat)
    end
    assert_redirected_to account_chats_path(@team_account)
    assert_not @team_chat.reload.discarded?
    assert_equal [ "restore_chat", @team_chat ], [ AuditLog.last.action, AuditLog.last.auditable ]
  end

  test "a chat in an account the user is not in is not found and stays as it was" do
    foreign_account = accounts(:other)
    assert_not foreign_account.memberships.exists?(user: @member)
    kept = foreign_account.chats.create!(model_id: "openrouter/auto", title: "Foreign")
    discarded = foreign_account.chats.create!(model_id: "openrouter/auto", title: "Foreign discarded")
    discarded.discard!

    assert_no_difference "AuditLog.count" do
      post account_chat_discard_path(foreign_account, kept)
      assert_response :not_found
      delete account_chat_discard_path(foreign_account, discarded)
      assert_response :not_found
    end
    assert_not kept.reload.discarded?
    assert discarded.reload.discarded?
  end

end
