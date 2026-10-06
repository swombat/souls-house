require "test_helper"
require_relative "../../support/github_import_fixtures"

module Agents
  class SandboxHomeProfileTest < ActiveSupport::TestCase

    include GithubImportFixtures

    test "only explicit approved request selects standard and passes reviewed policies" do
      request = import_request(sync_strategy: "standard", sync_configuration: { "auto_commit_paths" => [ "notes" ] })
      approve_fixture(request)
      agent = agents(:research_assistant)
      agent.update_columns(account_id: request.account_id, github_resident_import_id: request.id,
        home_profile: "portable_v1", portable_home_id: request.portable_home_id,
        github_repo_url: "https://github.com/#{request.repository}", github_repo_owner: "example", github_repo_name: "resident")
      args = env_args(agent)
      assert_includes args, "SOULSHOUSE_HOME_SYNC_STRATEGY=standard"
      assert_includes args, 'SOULSHOUSE_HOME_SYNC_CONFIGURATION={"auto_commit_paths":["notes"]}'
    end

    def env_args(agent)
      Agents::Sandbox.new(agent).send(:home_profile_env_args)
    end

    test "house residents get no imported home environment" do
      assert_equal [], env_args(agents(:research_assistant))
    end

    test "mira_v1 produces exactly the arguments it always has" do
      agent = agents(:research_assistant)
      agent.update!(home_profile: "mira_v1", portable_home_id: "test-mira")
      Agents::Config.stub(:imported_clamp_omit_forced_login?, false) do
        assert_equal [
          "-e", "SOULSHOUSE_HOME_PROFILE=mira_v1",
          "-e", "SOULSHOUSE_PORTABLE_HOME_ID=test-mira",
          "-e", "MIRA_ROOT=/home/agent/identity",
          "-e", "AGENT_REPO_PATH=/home/agent/identity",
          "-e", "TZ=Europe/Madrid"
        ], env_args(agent)
      end
    end

    test "portable_v1 passes its own profile and a neutral root, never MIRA_ROOT" do
      agent = agents(:research_assistant)
      agent.update!(home_profile: "portable_v1", portable_home_id: "test-lume")
      args = env_args(agent)
      assert_includes args, "SOULSHOUSE_HOME_PROFILE=portable_v1"
      assert_includes args, "SOULSHOUSE_HOME_ROOT=/home/agent/identity"
      assert_includes args, "AGENT_REPO_PATH=/home/agent/identity"
      assert_not args.any? { |arg| arg.start_with?("MIRA_ROOT") }
      assert_not_includes args, "SOULSHOUSE_HOME_PROFILE=mira_v1"
    end

    test "an unknown stored profile refuses container creation" do
      agent = agents(:research_assistant)
      agent.update_column(:home_profile, "mira_v2")
      error = assert_raises(Agents::Sandbox::SandboxError) { env_args(agent) }
      assert_match "unknown resident home profile", error.message
    end

    test "forced login switch is off by default and only reaches imported homes" do
      agent = agents(:research_assistant)
      assert_not Agents::Config.imported_clamp_omit_forced_login?
      Agents::Config.stub(:imported_clamp_omit_forced_login?, true) do
        assert_equal [], env_args(agent)
        agent.update!(home_profile: "portable_v1", portable_home_id: "test-lume")
        assert_includes env_args(agent), "SOULSHOUSE_IMPORTED_CLAMP_OMIT_FORCED_LOGIN=1"
      end
      assert_not_includes env_args(agent), "SOULSHOUSE_IMPORTED_CLAMP_OMIT_FORCED_LOGIN=1"
    end

    test "house trust guard is off by default and only reaches house residents" do
      agent = agents(:research_assistant)
      sandbox = Agents::Sandbox.new(agent)
      assert_not Agents::Config.require_house_trust?
      assert_equal [], sandbox.send(:house_trust_env_args)
      Agents::Config.stub(:require_house_trust?, true) do
        assert_equal [ "-e", "SOULSHOUSE_REQUIRE_HOUSE_TRUST=1" ], sandbox.send(:house_trust_env_args)
        agent.update!(home_profile: "mira_v1", portable_home_id: "test-mira")
        assert_equal [], sandbox.send(:house_trust_env_args)
      end
    end

  end
end
