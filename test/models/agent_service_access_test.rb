require "test_helper"

class AgentServiceAccessTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      container_name: "test-agent-container"
    )
    @connection = @account.service_connections.create!(
      connected_by_user: users(:user_1),
      provider: "dropbox",
      external_subject_id: "dbid:callback-test",
      external_identity: "dropbox-test@example.test",
      management_scope: "personal",
      credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "encrypted-test-token" },
      credential_metadata: {
        "granted_scopes" => Services::Catalog::DROPBOX_READ,
        "credential_strategy" => "self_refreshing"
      }
    )
  end

  test "creating access schedules runtime reconciliation" do
    assert_enqueued_with(
      job: AccountAgentCredentialsRefreshJob,
      args: [ @account.id, @agent.id, { manifest_only: true } ]
    ) do
      @agent.agent_service_accesses.create!(
        service_connection: @connection,
        enabled: true
      )
    end
  end

  test "changing enabled access schedules runtime reconciliation" do
    access = @agent.agent_service_accesses.create!(
      service_connection: @connection,
      enabled: true
    )
    clear_enqueued_jobs

    assert_enqueued_with(
      job: AccountAgentCredentialsRefreshJob,
      args: [ @account.id, @agent.id, { manifest_only: true } ]
    ) do
      access.update!(enabled: false)
    end
  end

  test "destroying access schedules runtime reconciliation" do
    access = @agent.agent_service_accesses.create!(
      service_connection: @connection,
      enabled: true
    )
    clear_enqueued_jobs

    assert_enqueued_with(
      job: AccountAgentCredentialsRefreshJob,
      args: [ @account.id, @agent.id, { manifest_only: true } ]
    ) do
      access.destroy!
    end
  end

end
