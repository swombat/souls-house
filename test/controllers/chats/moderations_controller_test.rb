require "test_helper"

class Chats::ModerationsControllerTest < ActionDispatch::IntegrationTest

  include ActiveJob::TestHelper

  setup do
    @admin_user = users(:site_admin_user)
    @admin_account = accounts(:site_admin_account)
    @user = users(:user_1)
    @account = accounts(:personal_account)
  end

  test "site admin queues only unmoderated messages with content, and the audit records the count" do
    chat = @admin_account.chats.create!(model_id: "openrouter/auto", title: "Admin Chat")
    pending = chat.messages.create!(role: "assistant", content: "Not yet moderated")
    chat.messages.create!(role: "assistant", content: "Already moderated", moderated_at: 1.hour.ago)
    chat.messages.create!(role: "assistant", content: "")

    post login_path, params: { email_address: @admin_user.email_address, password: "password123" }
    clear_enqueued_jobs

    assert_difference "AuditLog.count", 1 do
      assert_enqueued_jobs 1, only: ModerateMessageJob do
        post account_chat_moderation_path(@admin_account, chat), headers: { "Accept" => "application/json" }
      end
    end

    assert_response :success
    assert_equal 1, JSON.parse(response.body)["queued"]
    assert_enqueued_with job: ModerateMessageJob, args: [ pending ]
    audit = AuditLog.last
    assert_equal "moderate_all_messages", audit.action
    assert_equal chat, audit.auditable
  end

  test "non site admin is refused and nothing is queued or audited" do
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Test Chat")
    chat.messages.create!(role: "assistant", content: "Not yet moderated")

    post login_path, params: { email_address: @user.email_address, password: "password123" }
    clear_enqueued_jobs

    assert_no_difference "AuditLog.count" do
      assert_no_enqueued_jobs only: ModerateMessageJob do
        post account_chat_moderation_path(@account, chat)
      end
    end

    assert_redirected_to account_chats_path(@account)
    assert_match(/permission/, flash[:alert])
  end

end
