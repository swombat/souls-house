require "test_helper"
require "webmock/minitest"

class Accounts::WatchedRepositoriesControllerTest < ActionDispatch::IntegrationTest

  setup do
    @owner = users(:user_1)
    @member = users(:existing_user)
    @account = accounts(:team_account)
    @connection = github_connection(@account, @owner)
  end

  test "a member who can manage the GitHub connection connects a repository and the hook is installed" do
    stub_request(:get, "https://api.github.com/repos/swombat/site")
      .to_return(status: 200, body: { id: 42, full_name: "swombat/site", private: true }.to_json, headers: json)
    hook = stub_request(:post, "https://api.github.com/repos/swombat/site/hooks")
      .to_return(status: 201, body: { id: 9001 }.to_json, headers: json)
    sign_in @owner

    assert_difference "WatchedRepository.count", 1 do
      post account_watched_repositories_path(@account), params: { service_connection_id: @connection.public_id, full_name: "swombat/site" }
    end

    assert_redirected_to account_integrations_path(@account)
    assert_requested hook
    repository = @account.watched_repositories.live.sole
    assert_equal "swombat/site", repository.full_name
    assert_equal "installing", repository.hook_status
    assert_equal 9001, repository.hook_id.to_i
    assert_equal @owner, repository.created_by_user
    assert AuditLog.exists?(action: "repository_watch.connect", auditable: repository)
  end

  test "GitHub refusing the hook leaves the repository needing manual setup" do
    stub_request(:get, "https://api.github.com/repos/swombat/site")
      .to_return(status: 200, body: { id: 42, full_name: "swombat/site", private: true }.to_json, headers: json)
    stub_request(:post, "https://api.github.com/repos/swombat/site/hooks")
      .to_return(status: 404, body: { message: "Not Found" }.to_json, headers: json)
    sign_in @owner

    post account_watched_repositories_path(@account), params: { service_connection_id: @connection.public_id, full_name: "swombat/site" }

    assert_equal "manual", @account.watched_repositories.live.sole.hook_status
    assert_match(/admin of the repository must add it/, flash[:notice])
  end

  test "a repository the connection cannot see is refused with the reason" do
    stub_request(:get, "https://api.github.com/repos/swombat/hidden").to_return(status: 404, body: "{}", headers: json)
    sign_in @owner

    assert_no_difference "WatchedRepository.count" do
      post account_watched_repositories_path(@account), params: { service_connection_id: @connection.public_id, full_name: "swombat/hidden" }
    end
    assert_match(/cannot see swombat\/hidden/, flash[:alert])
  end

  test "a member who can neither manage nor provision the connection cannot connect a repository" do
    sign_in @member

    assert_no_difference "WatchedRepository.count" do
      post account_watched_repositories_path(@account), params: { service_connection_id: @connection.public_id, full_name: "swombat/site" }
    end
    assert_equal "You cannot connect repositories to this GitHub connection", flash[:alert]
    assert_not_requested :any, /api.github.com/
  end

  test "a connection from another account is not found" do
    other = github_connection(accounts(:personal_account), @owner, subject: "other-account")
    sign_in @owner

    assert_no_difference "WatchedRepository.count" do
      post account_watched_repositories_path(@account), params: { service_connection_id: other.public_id, full_name: "swombat/site" }
    end
    assert_equal "You cannot connect repositories to this GitHub connection", flash[:alert]
  end

  test "disconnecting deletes the hook, marks the repository removed and cancels armed watches" do
    repository = watched_repository(hook_id: 9001)
    watch = arm(repository)
    delete_hook = stub_request(:delete, "https://api.github.com/repos/swombat/site/hooks/9001").to_return(status: 204)
    sign_in @owner

    delete account_watched_repository_path(@account, repository)

    assert_redirected_to account_integrations_path(@account)
    assert_requested delete_hook
    assert repository.reload.removed?
    assert_equal "removed", repository.hook_status
    assert_equal "cancelled", watch.reload.state
    assert_equal "repository disconnected", watch.cancel_reason
    assert AuditLog.exists?(action: "repository_watch.disconnect", auditable: repository)
  end

  test "a member who cannot manage the connection cannot disconnect" do
    repository = watched_repository
    sign_in @member

    delete account_watched_repository_path(@account, repository)

    assert_not repository.reload.removed?
    assert_equal "You cannot disconnect this repository", flash[:alert]
  end

  test "an outsider cannot reach another account's repository" do
    repository = watched_repository
    sign_in users(:existing_user)

    delete account_watched_repository_path(accounts(:personal_account), repository)

    assert_not repository.reload.removed?
  end

  private

  def json
    { "Content-Type" => "application/json" }
  end

  def github_connection(account, user, subject: "github-watches")
    account.service_connections.create!(
      connected_by_user: user,
      provider: "github",
      external_subject_id: subject,
      external_identity: "swombat",
      label: "swombat",
      management_scope: "personal",
      status: "connected",
      credential_kind: "token",
      credential_fingerprint: "#{subject}-fingerprint",
      credential_payload_hash: { "token" => "github_pat_test" },
      credential_metadata: { "credential_strategy" => "static" }
    )
  end

  def watched_repository(**attributes)
    WatchedRepository.create!(
      account: @account, service_connection: @connection, created_by_user: @owner,
      owner: "swombat", name: "site", full_name: "swombat/site", hook_status: "installed", **attributes
    )
  end

  def arm(repository)
    chat = @account.chats.create!(model_id: "openrouter/auto", title: "Release room")
    RepositoryWatch.create!(
      account: @account, watched_repository: repository, chat: chat, created_by_user: @owner,
      event_kind: "workflow_run", filter: { "head_sha" => "a" * 40 }, expires_at: 1.day.from_now
    )
  end

end
