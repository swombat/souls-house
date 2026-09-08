require "test_helper"
require "open3"
require "tmpdir"
require "fileutils"

class RuntimeBuildTest < ActiveSupport::TestCase

  test "default house name is literal data and exported host wins" do
    with_runtime do |root, env|
      # Neither shell metacharacters nor spaces in the env file are executable.
      File.open("#{root}/config/house.env", "a") do |file|
        file.puts "HOUSE_MAIL_FROM=My House <hello@example.org>"
        file.puts "HOUSE_TRANSITION_ALIASES=$(touch #{root}/executed)"
      end
      output, status = Open3.capture2e(env.merge("HOUSE_HOST" => "198.51.100.9"), "#{root}/scripts/build-agent-runtime", "testsha")
      assert status.success?, output
      args = JSON.parse(output.lines.last)
      assert_equal "ssh://deploy@198.51.100.9:22", args[1]
      assert_includes args, "helixkit-agent-runtime:latest"
      assert_not File.exist?("#{root}/executed")
    end
  end

  test "runtime build tags exactly the configured image including registry port and custom tag" do
    with_runtime do |root, env|
      output, status = Open3.capture2e(env.merge("HOUSE_AGENT_IMAGE" => "registry.example:5000/my/runtime:stable"),
                                     "#{root}/scripts/build-agent-runtime", "testsha")
      assert status.success?, output
      args = JSON.parse(output.lines.last)
      assert_includes args, "registry.example:5000/my/runtime:stable"
      assert_includes args, "registry.example:5000/my/runtime:testsha"
      assert_includes args, "registry.example:5000/my/runtime:latest"
    end
  end

  test "legacy runtime overrides remain supported" do
    with_runtime do |root, env|
      output, status = Open3.capture2e(env.merge("HELIXKIT_AGENT_RUNTIME_IMAGE" => "legacy-runtime",
                                               "HELIXKIT_AGENT_RUNTIME_DOCKER_HOST" => "ssh://override"),
                                     "#{root}/scripts/build-agent-runtime", "testsha")
      assert status.success?, output
      args = JSON.parse(output.lines.last)
      assert_equal "ssh://override", args[1]
      assert_includes args, "legacy-runtime:latest"
    end
  end

  private

  def with_runtime
    Dir.mktmpdir("runtime-build-test") do |root|
      %w[config scripts agent-runtime stub].each { |dir| FileUtils.mkdir_p("#{root}/#{dir}") }
      %w[config/house.rb scripts/build-agent-runtime agent-runtime/chaos-ref].each do |path|
        FileUtils.cp(Rails.root.join(path), "#{root}/#{path}")
      end
      FileUtils.cp(Rails.root.join("config/house.env.example"), "#{root}/config/house.env")
      File.write("#{root}/stub/docker", "#!/usr/bin/env ruby\nrequire 'json'\nputs JSON.generate(ARGV)\n")
      File.chmod(0o755, "#{root}/stub/docker")
      env = ENV.keys.grep(/\A(?:HOUSE_|HELIXKIT_)/).to_h { |key| [ key, nil ] }
      env["PATH"] = "#{root}/stub:#{ENV.fetch('PATH')}"
      yield root, env
    end
  end

end
