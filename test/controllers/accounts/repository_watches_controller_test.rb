require "test_helper"

class Accounts::RepositoryWatchesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @owner = users(:user_1)
    @member = users(:existing_user)
    @account = accounts(:team_account)
    connection = @account.service_connections.create!(
      connected_by_user: @owner,
      provider: "github",
      external_subject_id: "github-watch-cancel",
      external_identity: "swombat",
      label: "swombat",
      management_scope: "personal",
      status: "connected",
      credential_kind: "token",
      credential_fingerprint: "github-watch-cancel-fingerprint",
      credential_payload_hash: { "token" => "github_pat_test" },
      credential_metadata: { "credential_strategy" => "static" }
    )
    repository = WatchedRepository.create!(
      account: @account, service_connection: connection, created_by_user: @owner,
      owner: "swombat", name: "site", full_name: "swombat/site", hook_status: "installed"
    )
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Release room")
    @watch = RepositoryWatch.create!(
      account: @account, watched_repository: repository, chat: chat, created_by_agent: agents(:other_account_agent),
      event_kind: "workflow_run", filter: { "head_sha" => "b" * 40 }, expires_at: 1.day.from_now
    )
  end

  test "any account member may cancel an armed watch, even one a resident armed" do
    sign_in @member

    delete account_repository_watch_path(@account, @watch)

    assert_redirected_to account_integrations_path(@account)
    @watch.reload
    assert_equal "cancelled", @watch.state
    assert_match(/\Acancelled by /, @watch.cancel_reason)
    assert AuditLog.exists?(action: "repository_watch.cancel", auditable: @watch)
  end

  test "a watch that is no longer armed stays as it is" do
    @watch.update!(state: "fulfilled", fulfilled_at: Time.current)
    sign_in @member

    delete account_repository_watch_path(@account, @watch)

    assert_equal "fulfilled", @watch.reload.state
    assert_equal "That watch is no longer armed", flash[:alert]
  end

  test "a watch from another account is not found through this one" do
    sign_in @owner

    delete account_repository_watch_path(accounts(:personal_account), @watch)

    assert_response :not_found
    assert_equal "armed", @watch.reload.state
  end

end
