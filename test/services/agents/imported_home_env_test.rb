require "test_helper"
require_relative "../../support/github_import_fixtures"

# docs/2026-10-10-vm-imports.md, points 5 and 6: one imported-home
# environment and one trust check for the house sandbox and a VM, and the
# runner's fixed copies kept equal to them.
module Agents
  class ImportedHomeEnvTest < ActiveSupport::TestCase

    include GithubImportFixtures

    IMAGE = "sha256:#{'a' * 64}".freeze
    RUNNER = Rails.root.join("host-runner/souls_house_runner.py").read

    setup do
      @previous_domain = ENV["SOULSHOUSE_DOMAIN"]
      ENV["SOULSHOUSE_DOMAIN"] = "souls.example"
      @request = import_request(sync_strategy: "standard", sync_configuration: { "auto_commit_paths" => [ "notes" ] })
      approve_fixture(@request)
      @agent = agents(:research_assistant)
      @agent.update_columns(account_id: @request.account_id, github_resident_import_id: @request.id,
        home_profile: "portable_v1", portable_home_id: @request.portable_home_id, trigger_bearer_token: "trig",
        github_repo_url: "https://github.com/#{@request.repository}", github_repo_owner: "example", github_repo_name: "resident")
      @agent.reload
    end

    teardown { ENV["SOULSHOUSE_DOMAIN"] = @previous_domain }

    def runner_names(constant)
      block = RUNNER[/^#{constant} = frozenset\(\{(.*?)\}\)/m, 1] || RUNNER[/^#{constant} = \((.*?)\)/m, 1]
      block.scan(/"([A-Z][A-Z0-9_]*)"/).flatten
    end

    def vm!(kind: "github_import", facts: {})
      placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", kind:, state: "ready", provider_server_id: 4343)
      enrollment, token = RunnerEnrollment.mint!(placement:)
      enrollment.confirm_provider_server!(4343)
      enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4343, facts:, nonce: SecureRandom.hex(16))
      enrollment.update!(last_facts: facts)
      @agent.reload
      enrollment
    end

    test "the runner carries the house's trust check byte for byte" do
      runner_copy = RUNNER[/^RUNTIME_TRUST_CHECK = """(.*?)"""/m, 1]
      assert runner_copy, "the runner defines RUNTIME_TRUST_CHECK"
      assert_equal ImportedHomeEnv::RUNTIME_TRUST_CHECK, runner_copy
      assert_equal ImportedHomeEnv.trust_check(@agent).keys, runner_names("TRUST_CHECK_ENV_KEYS")
      assert_equal Agents::RemoteRuntime::RUNTIME_TRUST_CHECK_VERSION, RUNNER[/^RUNTIME_TRUST_CHECK_VERSION = (\d+)/, 1].to_i
    end

    test "every house service token reaches a VM resident through the runner's allowlist" do
      names = Account::HOUSE_SERVICE_TOKENS.values.map { |config| config.fetch(:env) }
      assert_empty names - runner_names("RESIDENT_ENV_KEYS")
    end

    test "every name a GitHub import's runtime is given is on the runner's allowlist, and nothing for mira_v1" do
      allowed = runner_names("RESIDENT_ENV_KEYS") + runner_names("IMPORTED_HOME_ENV_KEYS")
      Agents::Config.stub(:imported_clamp_omit_forced_login?, true) do
        ImportedHomeEnv.stub(:oauth_trust_required?, true) do
          names = ImportedHomeEnv.for(@agent).keys
          assert_includes names, "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST"
          assert_includes names, "SOULSHOUSE_IMPORTED_CLAMP_OMIT_FORCED_LOGIN"
          assert_empty names - allowed
        end
      end
      assert_not_includes allowed, "MIRA_ROOT"
    end

    test "the sandbox passes exactly what the shared environment says" do
      args = Agents::Sandbox.new(@agent).send(:home_profile_env_args)
      assert_equal ImportedHomeEnv.for(@agent).flat_map { |name, value| [ "-e", "#{name}=#{value}" ] }, args
      assert_includes args, "SOULSHOUSE_GITHUB_IMPORT_ID=#{@request.id}"
      assert_includes args, 'SOULSHOUSE_HOME_SYNC_CONFIGURATION={"auto_commit_paths":["notes"]}'
    end

    test "a GitHub import on its own VM is given its imported-home environment; no other imported home runs there" do
      vm!
      env = Agents::RemoteRuntime.environment(@agent)
      assert_equal ImportedHomeEnv.for(@agent), env.slice(*ImportedHomeEnv.for(@agent).keys)
      assert_equal "portable_v1", env["SOULSHOUSE_HOME_PROFILE"]

      @agent.placement.update_columns(kind: "archive_import")
      assert_raises(Agents::RemoteRuntime::Unavailable) { Agents::RemoteRuntime.environment(@agent.reload) }

      @agent.update_columns(github_resident_import_id: nil, home_profile: "mira_v1")
      @agent.placement.update_columns(kind: "github_import")
      assert_raises(Agents::RemoteRuntime::Unavailable) { Agents::RemoteRuntime.environment(@agent.reload) }
    end

    test "an import whose approval no longer holds is not given an environment" do
      vm!
      @request.update_columns(approved_commit_sha: "b" * 40)
      assert_raises(Agent::RuntimeAvailability::Unavailable) { Agents::RemoteRuntime.environment(@agent.reload) }
    end

    test "the trust check goes only to a runner that says it has it, with the image and the values" do
      enrollment = vm!
      error = assert_raises(Agents::RemoteRuntime::Unavailable) { Agents::RemoteRuntime.check_runtime_trust!(@agent, image: IMAGE) }
      assert_match(/newer runner/, error.message)
      assert_equal 0, RunnerCommand.where(kind: "check_runtime_trust").count

      enrollment.update!(last_facts: { "runtime_trust_check" => Agents::RemoteRuntime::RUNTIME_TRUST_CHECK_VERSION })
      command = Agents::RemoteRuntime.check_runtime_trust!(@agent.reload, image: IMAGE)
      payload = JSON.parse(command.payload_json)
      assert_equal %w[container_name env image], payload.keys.sort
      assert_equal IMAGE, payload["image"]
      assert_equal ImportedHomeEnv.trust_check(@agent), payload["env"]
      assert_equal "0", payload.dig("env", "SOULSHOUSE_GITHUB_IMPORT_REQUIRE_OAUTH_TRUST")
    end

    test "the trust check is refused for anything but a GitHub import on its own VM" do
      vm!(kind: "archive_import", facts: { "runtime_trust_check" => 1 })
      assert_raises(Agents::RemoteRuntime::Unavailable) { Agents::RemoteRuntime.check_runtime_trust!(@agent, image: IMAGE) }
      assert_equal 0, RunnerCommand.where(kind: "check_runtime_trust").count
    end

    test "only an answer that says trusted is trusted" do
      enrollment = vm!(facts: { "runtime_trust_check" => 1 })
      outcome = lambda do |state, result|
        command = Agents::RemoteRuntime.check_runtime_trust!(@agent, image: IMAGE)
        command.update_columns(state:, result:)
        Agents::RemoteRuntime.runtime_trust_outcome(command)
      end
      assert_equal :pending, outcome.call("queued", nil)
      assert_equal :pending, outcome.call("delivered", nil)
      assert_equal :trusted, outcome.call("done", { "outcome" => "done", "result" => { "trust" => "trusted" } })
      assert_equal :untrusted, outcome.call("done", { "outcome" => "done", "result" => { "trust" => "untrusted" } })
      assert_equal :unsupported, outcome.call("done", { "outcome" => "done", "result" => { "trust" => "unsupported" } })
      assert_equal :failed, outcome.call("done", { "outcome" => "done", "result" => { "trust" => "yes" } })
      assert_equal :failed, outcome.call("done", { "outcome" => "done" })
      assert_equal :failed, outcome.call("failed", { "outcome" => "failed", "result" => { "trust" => "trusted" } })
      assert_equal :failed, outcome.call("unknown", nil)
      assert enrollment
    end

  end
end
