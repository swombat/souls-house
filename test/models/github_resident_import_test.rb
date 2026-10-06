require "test_helper"
require_relative "../support/github_import_fixtures"

class GithubResidentImportTest < ActiveSupport::TestCase

  include GithubImportFixtures

  test "current account and connection permissions authorize approval and remain live" do
    assert GithubResidentImport.requestable_by?(accounts(:team_account), users(:user_1))
    assert_not GithubResidentImport.requestable_by?(accounts(:team_account), users(:existing_user))
    request = import_request
    approver = users(:user_1)
    assert_not approver.site_admin
    assert request.approvable_by?(approver)
    assert_not request.approvable_by?(users(:existing_user))
    assert_raises(Account::NotAuthorized) { request.approve!(users(:existing_user), review_revision: request.review_revision) }
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      assert_enqueued_with(job: GithubResidentImportJob, args: [ request.id ]) do
        request.approve!(approver, review_revision: request.review_revision)
      end
    end
    assert_nil request.approval_error
    assert_equal approver, request.approved_by
    assert_equal request.commit_sha, request.approved_commit_sha
    assert_equal request.credential_fingerprint, request.approved_credential_fingerprint

    request.account.memberships.find_by!(user: approver).update_column(:role, "member")
    assert_match(/Approver no longer has permission/, request.approval_error)
  end

  test "approval expires when the approver loses provisioning permission for the selected connection" do
    connection = import_connection(account: accounts(:team_account))
    request = import_request(connection: connection)
    approver = users(:user_1)
    assert request.approvable_by?(approver)
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      request.approve!(approver, review_revision: request.review_revision)
    end
    assert_nil request.approval_error

    connection.update!(connected_by_user: users(:existing_user))
    assert request.account.service_credentials_manageable_by?(approver)
    assert_not connection.reload.provisionable_by?(approver)
    assert_match(/Approver no longer has permission/, request.approval_error)
  end

  test "rotation disconnect repository changes and resident configuration changes fail closed" do
    request = import_request
    approve_fixture(request)
    connection = request.service_connection
    connection.update!(credential_fingerprint: "changed")
    assert_match(/credential changed/, request.approval_error)
    connection.update!(credential_fingerprint: request.credential_fingerprint, status: "revoked")
    assert_match(/no longer connected/, request.approval_error)
    connection.update!(status: "connected", credential_metadata: connection.credential_metadata.merge("repository" => "other/repo"))
    assert_match(/repository configuration changed/, request.approval_error)
  end

  test "stale review and classic tokens cannot be approved" do
    request = import_request
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      assert_raises(ArgumentError) { request.approve!(users(:user_1), review_revision: "old") }
      request.service_connection.credential_payload_hash = { "token" => "ghp_synthetic" }
      request.service_connection.save!
      assert_raises(ArgumentError) { request.approve!(users(:user_1), review_revision: request.review_revision) }
    end
  end

  test "reviewed source configuration cannot be mass changed" do
    request = import_request
    assert_not request.update(branch: "other")
    assert_not request.update(commit_sha: "b" * 40)
    assert_not request.update(account: accounts(:team_account))
  end

  test "branch advancement is disclosed separately without changing the pinned seed" do
    request = import_request
    source = source_stub(request)
    source.define_singleton_method(:with_checkout) do |**_, &block|
      block.call("/synthetic", { "identity_id" => request.portable_home_id }, "b" * 40, "main")
    end
    Agents::GithubImportSource.stub(:new, source) { request.approve!(users(:user_1), review_revision: request.review_revision) }
    assert_equal "a" * 40, request.approved_commit_sha
    assert_equal "b" * 40, request.observed_branch_sha_at_approval
    assert_nil request.approval_error
  end

  test "new GitHub imports never inherit service defaults" do
    request = import_request
    request.service_connection.update!(enabled_for_new_agents: true)
    agent = request.create_agent!(account: request.account, name: "No inherited secrets", runtime: "offline",
      home_profile: "portable_v1", portable_home_id: request.portable_home_id)
    assert_empty agent.agent_service_accesses
    another = import_connection(token: "github_pat_other")
    another.update!(enabled_for_new_agents: true)
    another.send(:apply_default_accesses)
    assert_empty agent.reload.agent_service_accesses
  end

  test "credential rotation cannot deliver replaced token through service manifest or reconciliation" do
    request = import_request
    approve_fixture(request)
    owner, repo = request.repository.split("/")
    agent = request.create_agent!(account: request.account, name: "Manifest gate", runtime: "external",
      active: true, home_profile: "portable_v1", portable_home_id: request.portable_home_id,
      github_repo_url: "https://github.com/#{request.repository}", github_repo_owner: owner, github_repo_name: repo,
      container_image: request.approved_image, uuid: SecureRandom.uuid)
    agent.update!(container_name: Agents::Resources.new(agent).container)
    agent.agent_service_accesses.create!(service_connection: request.service_connection)
    assert_equal "github_pat_synthetic", Agents::ServiceManifest.new(agent).to_h.dig("services", 0, "credentials", "token")
    connection = request.service_connection
    connection.credential_payload_hash = { "token" => "github_pat_rotated" }
    connection.update!(credential_fingerprint: "rotated")
    assert_empty Agents::ServiceManifest.new(agent.reload).to_h["services"]
    sandbox = Agents::Sandbox.new(agent)
    sandbox.define_singleton_method(:active_turn?) { false }
    sandbox.define_singleton_method(:container_exists?) { flunk "must not touch Docker before authorization" }
    Agents::Sandbox.stub(:new, sandbox) do
      assert_raises(Agent::RuntimeAvailability::Unavailable) { AccountAgentCredentialsRefreshJob.perform_now(agent.account_id, agent.id) }
    end
  end

  test "same request refreshes rotated credential review without replacing resident or identity" do
    request = import_request
    approve_fixture(request)
    owner, repo = request.repository.split("/")
    agent = request.create_agent!(account: request.account, name: "Rotation", runtime: "external",
      home_profile: "portable_v1", portable_home_id: request.portable_home_id, identity_seeded_at: Time.current,
      github_repo_url: "https://github.com/#{request.repository}", github_repo_owner: owner, github_repo_name: repo,
      container_image: request.approved_image)
    request.update!(status: "ready")
    connection = request.service_connection
    connection.credential_payload_hash = { "token" => "github_pat_rotated" }
    fingerprint = Services::GithubTokenAdapter.fingerprint("github_pat_rotated")
    connection.update!(credential_fingerprint: fingerprint)
    result = { credential_fingerprint: fingerprint,
      credential_metadata: Services::GithubTokenAdapter.authority_metadata("github_pat_rotated") }
    adapter = connection.definition.adapter
    definition = connection.definition
    adapter.stub(:connection_attributes, result) do
      definition.stub(:adapter, adapter) do
        connection.stub(:definition, definition) do
          Agents::GithubImportSource.stub(:new, source_stub(request)) { request.refresh_review!(request.requested_by) }
        end
      end
    end
    assert_equal "pending_review", request.reload.status
    assert_equal fingerprint, request.credential_fingerprint
    assert_equal agent.id, request.agent.id
    assert_equal agent.identity_seeded_at, request.agent.identity_seeded_at
    assert request.approval_error
    Agents::GithubImportSource.stub(:new, source_stub(request)) do
      request.approve!(users(:user_1), review_revision: request.review_revision)
    end
    assert_nil request.approval_error
    assert_equal fingerprint, request.approved_credential_fingerprint
  end

end
