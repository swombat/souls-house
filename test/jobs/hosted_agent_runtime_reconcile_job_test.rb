require "test_helper"
require_relative "../support/github_import_fixtures"

class HostedAgentRuntimeReconcileJobTest < ActiveJob::TestCase

  include GithubImportFixtures

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      container_name: "hk-agent-test",
      container_image: "helixkit-agent-runtime:latest",
      health_state: "healthy"
    )
  end

  test "recreates stale hosted sandbox while preserving volumes" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, true)
    sandbox.expect(:active_turn?, false)
    sandbox.expect(:recreate!, true)

    Agents::Sandbox.stub(:new, ->(agent) {
      assert_equal @agent, agent
      sandbox
    }) do
      perform_reconcile
    end

    sandbox.verify
  end

  test "skips current sandbox" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, false)

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      perform_reconcile
    end

    sandbox.verify
    assert true
  end

  test "retries active stale sandbox later" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, true)
    sandbox.expect(:active_turn?, true)

    assert_enqueued_with(job: HostedAgentRuntimeReconcileJob, args: [ @agent.id ]) do
      Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
        perform_reconcile
      end
    end

    sandbox.verify
  end

  test "returns a pinned managed runtime to the latest channel before reconciling" do
    @agent.update!(container_image: "helixkit-agent-runtime:canary-fix")
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, true)
    sandbox.expect(:active_turn?, false)
    sandbox.expect(:recreate!, true)

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      perform_reconcile
    end

    sandbox.verify
    assert_equal "helixkit-agent-runtime:latest", @agent.reload.container_image
  end

  test "preserves a deliberately custom runtime image" do
    @agent.update!(container_image: "example.com/resident/custom-runtime:v2")
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, false)

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      perform_reconcile
    end

    sandbox.verify
    assert_equal "example.com/resident/custom-runtime:v2", @agent.reload.container_image
  end

  test "new house runtime preserves ready import approval and credential delivery" do
    request = import_request
    approve_fixture(request)
    request.update!(status: "ready")
    owner, repo = request.repository.split("/")
    agent = request.create_agent!(account: request.account, name: "Managed import", runtime: "external",
      active: true, home_profile: "portable_v1", portable_home_id: request.portable_home_id,
      github_repo_url: "https://github.com/#{request.repository}", github_repo_owner: owner, github_repo_name: repo,
      container_image: "helixkit-agent-runtime:previous", uuid: SecureRandom.uuid)
    agent.agent_service_accesses.create!(service_connection: request.service_connection)
    approval = request.attributes.slice("approved_at", "approved_commit_sha", "approved_credential_fingerprint", "approved_image")
    calls = []
    sandbox = Agents::Sandbox.new(agent)
    sandbox.define_singleton_method(:stale_container?) { true }
    sandbox.define_singleton_method(:active_turn?) { false }
    sandbox.define_singleton_method(:container_exists?) { false }
    sandbox.define_singleton_method(:remove!) { |delete_volume:| calls << [ :remove, delete_volume ] }
    sandbox.define_singleton_method(:spawn!) do
      agent.github_resident_import.require_approval!
      calls << [ :spawn, agent.container_image, Agents::ServiceManifest.new(agent).to_h["services"] ]
    end

    Agents::Config.stub(:default_image, "helixkit-agent-runtime:new-deployment") do
      Agents::Sandbox.stub(:new, sandbox) { HostedAgentRuntimeReconcileJob.perform_now(agent.id) }
    end

    assert_equal [ :remove, false ], calls.first
    assert_equal [ :spawn, "helixkit-agent-runtime:new-deployment" ], calls.last.first(2)
    assert_equal "github_pat_synthetic", calls.last[2].first.dig("credentials", "token")
    assert_equal "helixkit-agent-runtime:new-deployment", agent.reload.container_image
    assert_equal "ready", request.reload.status
    assert_nil request.approval_error
    assert_equal approval, request.attributes.slice(*approval.keys)
  end

  private

  def perform_reconcile
    Agents::Config.stub(:default_image, "helixkit-agent-runtime:latest") do
      HostedAgentRuntimeReconcileJob.perform_now(@agent.id)
    end
  end

end
