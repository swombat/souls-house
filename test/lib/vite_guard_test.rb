require "minitest/autorun"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require_relative "../../config/vite_guard"

class ViteGuardTest < Minitest::Test

  def setup
    @root = Dir.mktmpdir("vite-guard-test")
    FileUtils.mkdir_p(File.join(@root, "config"))
    File.write(File.join(@root, "config", "vite.json"), "{}")
    ViteGuard.install!
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def runner
    ViteRuby::Runner.new(ViteRuby.new(root: @root, mode: "test"))
  end

  def test_refuses_without_node_modules_and_spawns_nothing
    spawned = []
    capture = ->(*args, **) { spawned << args; raise "spawned" }
    ViteRuby::IO.stub(:capture, capture) do
      Kernel.stub(:exec, capture) do
        error = assert_raises(ViteGuard::MissingViteError) { runner.run([ "build" ]) }
        assert_includes error.message, "bun install"
      end
    end
    assert_empty spawned
  end

  def test_runs_when_the_project_vite_is_installed
    bin = File.join(@root, "node_modules", ".bin", "vite")
    FileUtils.mkdir_p(File.dirname(bin))
    File.write(bin, "#!/bin/sh\n")
    File.chmod(0o755, bin)
    spawned = []
    ViteRuby::IO.stub(:capture, ->(*args, **) { spawned << args; [ "", "", nil ] }) do
      runner.run([ "build" ])
    end
    assert_equal 1, spawned.size
  end

  def test_install_is_idempotent
    ViteGuard.install!
    assert_equal 1, ViteRuby::Runner.ancestors.count(ViteGuard::RunnerGuard)
  end

end
