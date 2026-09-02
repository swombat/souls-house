require "test_helper"

module Agents
  class ConfigTest < ActiveSupport::TestCase

    test "development internal url follows PORT when explicit url is not configured" do
      old_internal_url = ENV["SOULSHOUSE_AGENT_INTERNAL_URL"]
      old_dev_web_port = ENV["SOULSHOUSE_DEV_WEB_PORT"]
      old_port = ENV["PORT"]
      ENV.delete("SOULSHOUSE_AGENT_INTERNAL_URL")
      ENV.delete("SOULSHOUSE_DEV_WEB_PORT")
      ENV["PORT"] = "3200"

      assert_equal "http://host.docker.internal:3200", Agents::Config.internal_url
    ensure
      ENV["SOULSHOUSE_AGENT_INTERNAL_URL"] = old_internal_url
      ENV["SOULSHOUSE_DEV_WEB_PORT"] = old_dev_web_port
      ENV["PORT"] = old_port
    end

    test "development internal url prefers the shared dev web port over process port" do
      old_internal_url = ENV["SOULSHOUSE_AGENT_INTERNAL_URL"]
      old_dev_web_port = ENV["SOULSHOUSE_DEV_WEB_PORT"]
      old_port = ENV["PORT"]
      ENV.delete("SOULSHOUSE_AGENT_INTERNAL_URL")
      ENV["SOULSHOUSE_DEV_WEB_PORT"] = "3100"
      ENV["PORT"] = "3300"

      assert_equal "http://host.docker.internal:3100", Agents::Config.internal_url
    ensure
      ENV["SOULSHOUSE_AGENT_INTERNAL_URL"] = old_internal_url
      ENV["SOULSHOUSE_DEV_WEB_PORT"] = old_dev_web_port
      ENV["PORT"] = old_port
    end

    test "cold starts can be configured per development instance" do
      old_value = ENV["SOULSHOUSE_AGENT_COLD_START"]
      ENV["SOULSHOUSE_AGENT_COLD_START"] = "true"

      assert Agents::Config.cold_start?
      assert_equal "no", Agents::Config.restart_policy

      ENV["SOULSHOUSE_AGENT_COLD_START"] = "false"

      assert_not Agents::Config.cold_start?
      assert_equal "unless-stopped", Agents::Config.restart_policy
    ensure
      ENV["SOULSHOUSE_AGENT_COLD_START"] = old_value
    end

  end
end
