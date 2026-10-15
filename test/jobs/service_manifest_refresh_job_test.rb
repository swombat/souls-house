require "test_helper"

class ServiceManifestRefreshJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(runtime: "external", container_name: "hk-agent-manifest")
    @account = @agent.account
    @connection = connection("first")
    @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    clear_enqueued_jobs
  end

  test "publishes an addition while busy without checking idleness or recreating" do
    written = publish do |yaml|
      assert_equal [ @connection.public_id ], YAML.safe_load(yaml)["services"].pluck("connection_id")
    end

    assert_equal 1, written.size
    assert_equal "provisioned", @access.reload.provisioning_status
    assert_equal @connection.credential_revision, @access.provisioned_revision
  end

  test "removes a disabled grant without restarting" do
    @access.update!(enabled: false)
    publish { |yaml| assert_empty YAML.safe_load(yaml)["services"] }
    assert_equal "removed", @access.reload.provisioning_status
    assert_nil @access.provisioned_revision
  end

  test "removes a destroyed grant" do
    @access.destroy!
    publish { |yaml| assert_empty YAML.safe_load(yaml)["services"] }
  end

  test "disconnected services are absent and not marked provisioned" do
    @connection.update!(status: "revoked")
    publish { |yaml| assert_empty YAML.safe_load(yaml)["services"] }
    assert_equal "removed", @access.reload.provisioning_status
  end

  test "a grant added during publication stays pending and queues another manifest refresh" do
    later = nil
    assert_enqueued_with(
      job: AccountAgentCredentialsRefreshJob,
      args: [ @account.id, @agent.id, { manifest_only: true } ]
    ) do
      publish do |_yaml|
        later = @agent.agent_service_accesses.create!(service_connection: connection("later"), enabled: true)
      end
    end
    assert_equal "pending", later.reload.provisioning_status
    assert_equal "provisioned", @access.reload.provisioning_status
  end

  test "a grant toggled during publication is not marked from a stale snapshot" do
    publish do |_yaml|
      @access.update!(enabled: false)
    end
    assert_equal "removal_pending", @access.reload.provisioning_status

    publish { |yaml| assert_empty YAML.safe_load(yaml)["services"] }
    assert_equal "removed", @access.reload.provisioning_status
  end

  test "rotated credentials during publication stay pending until the new snapshot is written" do
    publish do |_yaml|
      @connection.update!(credential_revision: @connection.credential_revision + 1)
    end
    assert_equal "pending", @access.reload.provisioning_status
    assert_nil @access.provisioned_revision

    publish do |yaml|
      assert_equal @connection.credential_revision, YAML.safe_load(yaml)["services"].first["credential_revision"]
    end
    assert_equal @connection.credential_revision, @access.reload.provisioned_revision
  end

  test "broker token cache refresh during publication does not strand a pending grant" do
    @connection.update!(
      provider: "google_workspace",
      credential_metadata: { "credential_strategy" => "refresh_broker" }
    )
    clear_enqueued_jobs
    before_refresh = @connection.updated_at
    Agents::Config.stub(:internal_url, "https://house.example.test") do
      publish do |yaml|
        entry = YAML.safe_load(yaml)["services"].first
        assert_equal "refresh_broker", entry["credential_strategy"]
        assert_not_includes yaml, "rotated-cache-token"
        @connection.replace_credential_payload_without_reconciliation!(
          "access_token" => "rotated-cache-token", "refresh_token" => "synthetic-refresh"
        )
      end
    end
    assert_operator @connection.updated_at, :>, before_refresh
    assert_no_enqueued_jobs only: AccountAgentCredentialsRefreshJob
    assert_equal "provisioned", @access.reload.provisioning_status
    assert_equal @connection.credential_revision, @access.provisioned_revision
  end

  test "a stopped or missing runtime uses the existing recreate fallback" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:refresh_service_manifest!, false) { |yaml:| yaml.present? }
    sandbox.expect(:active_turn?, false)
    sandbox.expect(:recreate!, true)
    Agents::Sandbox.stub(:new, sandbox) { perform_refresh }
    assert sandbox.verify
    assert_equal "provisioned", @access.reload.provisioning_status
  end

  test "busy fallback preserves manifest-only intent on its deferred job" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:refresh_service_manifest!, false) { |yaml:| yaml.present? }
    sandbox.expect(:active_turn?, true)
    Agents::Sandbox.stub(:new, sandbox) do
      assert_enqueued_with(
        job: AccountAgentCredentialsRefreshJob,
        args: [ @account.id, @agent.id, { manifest_only: true } ]
      ) { perform_refresh }
    end
    assert sandbox.verify
    assert_equal "pending", @access.reload.provisioning_status
  end

  test "failed live write retries without marking provisioned or falling through to a restart" do
    sandbox = Object.new
    sandbox.define_singleton_method(:refresh_service_manifest!) { |yaml:| raise Agents::Sandbox::SandboxError, "manifest write failed" }
    Agents::Sandbox.stub(:new, sandbox) do
      assert_enqueued_with(job: AccountAgentCredentialsRefreshJob) { perform_refresh }
    end
    assert_equal "pending", @access.reload.provisioning_status
  end

  test "generic key refresh still recreates and is not absorbed by a preceding grant refresh" do
    publish { |_yaml| }
    sandbox = Minitest::Mock.new
    sandbox.expect(:active_turn?, false)
    sandbox.expect(:recreate!, true)
    Agents::Sandbox.stub(:new, sandbox) do
      AccountAgentCredentialsRefreshJob.perform_now(@account.id, @agent.id)
    end
    assert sandbox.verify
  end

  private

  def connection(subject)
    @account.service_connections.create!(
      connected_by_user: users(:user_1), provider: "dropbox",
      external_subject_id: "dbid:manifest-#{subject}", management_scope: "personal",
      credential_kind: "oauth2", status: "connected",
      credential_payload_hash: { "access_token" => "synthetic-token-#{subject}" },
      credential_metadata: { "granted_scopes" => Services::Catalog::DROPBOX_READ, "credential_strategy" => "static" }
    )
  end

  def perform_refresh
    AccountAgentCredentialsRefreshJob.perform_now(@account.id, @agent.id, manifest_only: true)
  end

  # No active_turn? or recreate! methods: either call fails this test.
  def publish
    written = []
    sandbox = Object.new
    writer = ->(yaml:) { written << yaml; yield yaml; true }
    sandbox.define_singleton_method(:refresh_service_manifest!, &writer)
    Agents::Sandbox.stub(:new, sandbox) { perform_refresh }
    written
  end

end
