require "test_helper"

module Agents
  class SandboxHomeProfileTest < ActiveSupport::TestCase

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

  end
end
