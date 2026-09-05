require "test_helper"

class Agents::HostingDiagnosticsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)

    Setting.instance.update!(allow_agents: true)

    post login_path, params: {
      email_address: @user.email_address,
      password: "password123"
    }
    assert_redirected_to root_path
  end

  test "show returns sandbox and filesystem diagnostics as json" do
    sandbox = Struct.new(:status).new({ docker_available: true })
    dump_factory = lambda do |_agent, target: :identity|
      Struct.new(:as_json).new({
        target: target,
        root: target == :container_home ? "/home/agent" : "/home/agent/identity",
        entries: []
      })
    end

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      Agents::FilesystemDump.stub(:new, dump_factory) do
        get account_agent_hosting_diagnostics_path(@account, @agent), as: :json
      end
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal true, body.dig("sandbox_status", "docker_available")
    assert_equal "/home/agent/identity", body.dig("filesystem_dump", "root")
    assert_equal "/home/agent", body.dig("container_filesystem_dump", "root")
  end

  test "show reports missing hosting config instead of raising" do
    Agents::Config.stub(:internal_url, -> { raise KeyError, "HELIXKIT_AGENT_INTERNAL_URL is required" }) do
      get account_agent_hosting_diagnostics_path(@account, @agent), as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_includes body.dig("sandbox_status", "configuration_error"), "HELIXKIT_AGENT_INTERNAL_URL is required"
  end

  test "show marks external agent oriented when daily journals already exist" do
    @agent.update!(runtime: "external", uuid: SecureRandom.uuid_v7, container_name: "hk-agent-test", health_state: "healthy")
    sandbox = Struct.new(:status).new({ docker_available: true })
    dump_factory = lambda do |_agent, target: :identity|
      Struct.new(:as_json).new({ target: target, root: target == :container_home ? "/home/agent" : "/home/agent/identity", entries: [] })
    end
    journal_status = Object.new
    def journal_status.entries? = true

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      Agents::FilesystemDump.stub(:new, dump_factory) do
        Agents::DailyJournalStatus.stub(:new, journal_status) do
          get account_agent_hosting_diagnostics_path(@account, @agent), as: :json
        end
      end
    end

    assert_response :success
    assert_predicate @agent.reload.oriented_at, :present?
  end

  test "file preview returns lazy filesystem preview" do
    preview_factory = lambda do |_agent, target: :identity|
      Object.new.tap do |preview|
        preview.define_singleton_method(:file_preview_json) do |_path|
          { target: target, path: "soul.md", content: "# Soul\n", previewable: true }
        end
      end
    end

    Agents::FilesystemDump.stub(:new, preview_factory) do
      get file_preview_account_agent_hosting_diagnostics_path(@account, @agent), params: { target: "identity", path: "soul.md" }, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "# Soul\n", body["content"]
    assert_equal "identity", body["target"]
  end

  test "sandbox recreation queues reconcile job for hosted agent" do
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      container_name: "hk-agent-test",
      container_image: "helixkit-agent-runtime:latest",
      health_state: "healthy"
    )

    assert_enqueued_with(job: HostedAgentRuntimeReconcileJob, args: [ @agent.id ]) do
      post account_agent_sandbox_recreation_path(@account, @agent)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "hosting")
    assert_match "Runtime image refresh queued", flash[:notice]
  end

  test "sandbox recreation refuses inline agent" do
    @agent.update!(runtime: "deprecated")

    assert_no_enqueued_jobs only: HostedAgentRuntimeReconcileJob do
      post account_agent_sandbox_recreation_path(@account, @agent)
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "hosting")
    assert_match "Only hosted agents", flash[:alert]
  end

end
