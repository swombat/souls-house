require "test_helper"

class Accounts::IntegrationsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @connection = @account.service_connections.create!(
      connected_by_user: @user,
      provider: "github",
      external_subject_id: "github-user-personal-services",
      external_identity: "owner",
      label: "owner/repository",
      management_scope: "personal",
      credential_kind: "token",
      credential_fingerprint: "personal-services-fingerprint",
      credential_payload_hash: { "token" => "github_pat_test" },
      credential_metadata: {
        "credential_strategy" => "static",
        "repository" => "owner/repository"
      }
    )
    @enabled_agent = agents(:research_assistant)
    @disabled_agent = agents(:code_reviewer)
    @enabled_agent.agent_service_accesses.create!(
      service_connection: @connection,
      enabled: true,
      provisioning_status: "provisioned"
    )
    sign_in @user
  end

  test "lists resident access for every personal service connection" do
    get account_integrations_path(@account)

    assert_response :success
    assert_equal "accounts/integrations", inertia_component
    assert_equal true, inertia_shared_props.fetch("can_manage_account")
    connection = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == @connection.public_id }
    residents = connection.fetch("residents")
    enabled = residents.find { |resident| resident.fetch("id") == @enabled_agent.to_param }
    disabled = residents.find { |resident| resident.fetch("id") == @disabled_agent.to_param }

    assert_equal true, enabled.fetch("enabled")
    assert_equal "provisioned", enabled.fetch("provisioning_status")
    assert_equal false, disabled.fetch("enabled")
    assert_equal(
      account_agent_service_access_path(@account, @enabled_agent, @connection.public_id),
      enabled.fetch("access_update_url")
    )
  end

  test "a Tailscale connection lists each granted resident's sign-in panel" do
    tailnet = @account.service_connections.create!(
      connected_by_user: @user,
      provider: "tailscale",
      external_subject_id: "tailnet-sign-in",
      external_identity: "Tailnet",
      label: "Tailnet",
      management_scope: "personal",
      credential_kind: "none",
      credential_fingerprint: "tailnet-sign-in-fingerprint",
      credential_payload_hash: {},
      credential_metadata: {}
    )
    @enabled_agent.agent_service_accesses.create!(service_connection: tailnet, enabled: true, provisioning_status: "provisioned")

    get account_integrations_path(@account)

    residents = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == tailnet.public_id }.fetch("residents")
    enabled = residents.find { |resident| resident.fetch("id") == @enabled_agent.to_param }
    disabled = residents.find { |resident| resident.fetch("id") == @disabled_agent.to_param }
    assert_equal account_agent_tailnet_path(@account, @enabled_agent), enabled.fetch("tailnet_url")
    assert_equal edit_account_agent_path(@account, @enabled_agent, tab: "integrations"), enabled.fetch("integrations_url")
    assert_nil disabled.fetch("tailnet_url"), "no node to sign in until the resident is granted Tailscale"

    github = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == @connection.public_id }
    assert github.fetch("residents").all? { |resident| resident["tailnet_url"].nil? }
  end

  test "a member who can neither provision nor manage the tailnet gets no sign-in panels" do
    account = accounts(:team_account)
    member = users(:existing_user)
    tailnet = account.service_connections.create!(
      connected_by_user: @user,
      provider: "tailscale",
      external_subject_id: "team-tailnet",
      external_identity: "Tailnet",
      label: "Tailnet",
      management_scope: "account_managed",
      credential_kind: "none",
      credential_fingerprint: "team-tailnet-fingerprint",
      credential_payload_hash: {},
      credential_metadata: {}
    )
    agent = agents(:other_account_agent)
    agent.agent_service_accesses.create!(service_connection: tailnet, enabled: true, provisioning_status: "provisioned")
    sign_in member

    get account_integrations_path(account)

    assert_response :success
    connection = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == tailnet.public_id }
    assert_equal false, connection.fetch("can_provision")
    assert_equal false, connection.fetch("can_manage")
    resident = connection.fetch("residents").find { |item| item.fetch("id") == agent.to_param }
    assert_nil resident.fetch("tailnet_url"), "the tailnet endpoint would refuse this member, so no panel"
    assert_nil resident.fetch("integrations_url")
  end

  test "exposes one focused provider setup when requested" do
    get account_integrations_path(@account), params: { connect: "google_workspace" }

    assert_response :success
    assert_equal "google_workspace", inertia_shared_props.dig("focused_service", "key")
  end

  test "ignores an unknown focused provider" do
    get account_integrations_path(@account), params: { connect: "unknown" }

    assert_response :success
    assert_nil inertia_shared_props["focused_service"]
  end

  test "legacy personal services URL preserves focused provider" do
    get account_personal_services_path(@account), params: { connect: "google_workspace" }

    assert_redirected_to account_integrations_path(@account, connect: "google_workspace")
  end

  test "legacy account services URL redirects to integrations" do
    get account_services_path(@account)

    assert_redirected_to account_integrations_path(@account)
  end

  test "legacy account services URL preserves focused provider" do
    get account_services_path(@account), params: { connect: "dropbox" }

    assert_redirected_to account_integrations_path(@account, connect: "dropbox")
  end

  test "member sees own personal and account integrations but not another member's personal integrations" do
    account = accounts(:team_account)
    member = users(:existing_user)
    own = create_connection(account, member, "personal", "member-personal")
    shared = create_connection(account, @user, "account_managed", "shared-account")
    other = create_connection(account, @user, "personal", "owner-personal")
    sign_in member

    get account_integrations_path(account)

    assert_response :success
    props = inertia_shared_props
    assert_equal false, props.fetch("can_manage_account")
    connections = props.fetch("connections").index_by { |connection| connection.fetch("id") }
    assert_equal [ own.public_id, shared.public_id ].sort, connections.keys.sort
    assert_not connections.key?(other.public_id)
    assert_equal true, connections.fetch(own.public_id).fetch("can_manage")
    assert_equal true, connections.fetch(own.public_id).fetch("can_provision")
    assert_equal true, connections.fetch(own.public_id).fetch("can_delegate")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_manage")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_provision")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_delegate")
  end

  test "admin sees own personal and account integrations without treating account credentials as personal delegation" do
    account = accounts(:team_account)
    own = create_connection(account, @user, "personal", "owner-personal")
    shared = create_connection(account, users(:existing_user), "account_managed", "shared-account")
    other = create_connection(account, users(:existing_user), "personal", "member-personal")

    get account_integrations_path(account)

    assert_response :success
    props = inertia_shared_props
    assert_equal true, props.fetch("can_manage_account")
    connections = props.fetch("connections").index_by { |connection| connection.fetch("id") }
    assert_equal [ own.public_id, shared.public_id ].sort, connections.keys.sort
    assert_not connections.key?(other.public_id)
    assert_equal true, connections.fetch(shared.public_id).fetch("can_manage")
    assert_equal true, connections.fetch(shared.public_id).fetch("can_provision")
    assert_equal false, connections.fetch(shared.public_id).fetch("can_delegate")
    assert props.fetch("services").any? { |service| service.fetch("management_scopes").include?("account_managed") }
  end

  test "a GitHub card lists its connected repositories and their watches" do
    account = accounts(:team_account)
    github = account.service_connections.create!(
      connected_by_user: @user, provider: "github", external_subject_id: "github-repositories",
      external_identity: "owner", label: "owner", management_scope: "personal", status: "connected",
      credential_kind: "token", credential_fingerprint: "github-repositories-fingerprint",
      credential_payload_hash: { "token" => "github_pat_test" }, credential_metadata: { "credential_strategy" => "static" }
    )
    repository = WatchedRepository.create!(
      account: account, service_connection: github, created_by_user: @user,
      owner: "owner", name: "site", full_name: "owner/site", hook_status: "manual"
    )
    WatchedRepository.create!(
      account: account, service_connection: github, created_by_user: @user, owner: "owner", name: "gone",
      full_name: "owner/gone", hook_status: "removed", removed_at: Time.current
    )
    chat = account.chats.create!(model_id: "openrouter/auto", title: "Release room")
    armed = RepositoryWatch.create!(
      account: account, watched_repository: repository, chat: chat, created_by_user: @user,
      event_kind: "workflow_run", filter: { "head_sha" => "c" * 40 }, expires_at: 1.day.from_now
    )
    done = RepositoryWatch.create!(
      account: account, watched_repository: repository, chat: chat, created_by_user: @user, state: "fulfilled",
      event_kind: "deployment_status", filter: { "environment" => "production" }, expires_at: 1.day.from_now
    )

    get account_integrations_path(account)

    card = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == github.public_id }
    assert_equal true, card.fetch("can_manage_repositories")
    assert_equal account_watched_repositories_path(account), card.fetch("repositories_url")
    assert_equal [ "owner/site" ], card.fetch("repositories").map { |item| item.fetch("full_name") }, "removed repositories are not listed"
    listed = card.fetch("repositories").sole
    assert_equal "manual", listed.fetch("hook_status")
    assert_equal account_watched_repository_path(account, repository), listed.fetch("url")
    assert_equal repository.receiver_url, listed.dig("setup", "url")
    assert_equal repository.hook_secret, listed.dig("setup", "secret")
    watches = listed.fetch("watches").index_by { |watch| watch.fetch("id") }
    assert_equal [ armed.to_param, done.to_param ], listed.fetch("watches").map { |watch| watch.fetch("id") }, "armed first"
    assert_equal "Release room", watches.fetch(armed.to_param).fetch("chat_title")
    assert_equal account_chat_path(account, chat), watches.fetch(armed.to_param).fetch("chat_url")
    assert_equal account_repository_watch_path(account, armed), watches.fetch(armed.to_param).fetch("cancel_url")
    assert_nil watches.fetch(done.to_param).fetch("cancel_url")

    # GitHub connections are personal: only their owner (who can always
    # manage them) sees the card, so another member sees no secret at all.
    reset!
    @inertia_props = nil
    sign_in users(:existing_user)
    get account_integrations_path(account)

    assert_not inertia_shared_props.fetch("connections").any? { |item| item.fetch("id") == github.public_id }
  end

  test "other providers carry no repositories" do
    dropbox = create_connection(@account, @user, "personal", "no-repositories")
    get account_integrations_path(@account)
    card = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == dropbox.public_id }
    assert_not card.key?("repositories")
    github = inertia_shared_props.fetch("connections").find { |item| item.fetch("id") == @connection.public_id }
    assert_equal [], github.fetch("repositories")
  end

  private

  def create_connection(account, user, scope, subject)
    account.service_connections.create!(
      connected_by_user: user,
      provider: "dropbox",
      external_subject_id: subject,
      external_identity: "#{subject}@example.com",
      management_scope: scope,
      credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "test-only-token" },
      credential_metadata: { "credential_strategy" => "static" }
    )
  end

end
