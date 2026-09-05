require "test_helper"

module Agents
  class FilesystemDumpTest < ActiveSupport::TestCase

    test "builds a bounded identity filesystem dump" do
      agent = agents(:research_assistant)
      agent.update!(uuid: SecureRandom.uuid_v7)
      dump = Agents::FilesystemDump.new(agent)

      responses = lambda do |*args|
        case args
        when [ "info", "--format", "{{.ServerVersion}}" ]
          ok("27.0.0")
        when [ "volume", "inspect", "#{Agents::Resources.new(agent).volumes.fetch(:identity)}" ]
          ok("[]")
        when [ "run", "--rm", "-v", "#{Agents::Resources.new(agent).volumes.fetch(:identity)}:/identity:ro", "-w", "/identity", "busybox", "sh", "-c", args.last ]
          assert_includes args.last, "find . -maxdepth 6 -print"
          ok("directory\t\t./memory\nfile\t12\t./soul.md\n")
        else
          flunk "unexpected docker args: #{args.inspect}"
        end
      end

      dump.stub(:docker_capture, responses) do
        json = dump.as_json
        assert_nil json[:error]
        assert_equal "/home/agent/identity", json[:root]
        assert_equal "#{Agents::Resources.new(agent).volumes.fetch(:identity)}", json[:volume_name]
        assert_equal 2, json[:entries].length
        assert_equal({ path: "memory", name: "memory", type: "directory", depth: 0 }, json[:entries].first)
        assert_equal "soul.md", json[:entries].second[:path]
        assert_equal 12, json[:entries].second[:size_bytes]
        assert_equal true, json[:entries].second[:previewable]
        assert_not_includes json[:entries].second.keys, :content
      end
    end

    test "builds a bounded container home filesystem dump" do
      agent = agents(:research_assistant)
      agent.update!(
        uuid: SecureRandom.uuid_v7,
        container_name: "hk-agent-#{SecureRandom.hex(4)}"
      )
      dump = Agents::FilesystemDump.new(agent, target: :container_home)

      responses = lambda do |*args|
        case args
        when [ "info", "--format", "{{.ServerVersion}}" ]
          ok("27.0.0")
        when [ "container", "inspect", "--format", "{{.State.Running}}", agent.container_name ]
          ok("true\n")
        when [ "exec", agent.container_name, "sh", "-c", args.last ]
          command = args.last
          if command.include?("find . -maxdepth 6")
            assert_includes command, "./.chaos"
            assert_includes command, "./state"
            ok("file\t14\t./agent_write_test.txt\ndirectory\t\t./identity\n")
          else
            flunk "unexpected docker exec command: #{command}"
          end
        else
          flunk "unexpected docker args: #{args.inspect}"
        end
      end

      dump.stub(:docker_capture, responses) do
        json = dump.as_json
        assert_nil json[:error]
        assert_equal "/home/agent", json[:root]
        assert_equal :container_home, json[:target]
        assert_equal agent.container_name, json[:container_name]
        assert_equal 2, json[:entries].length
        assert_equal "agent_write_test.txt", json[:entries].first[:path]
        assert_equal 14, json[:entries].first[:size_bytes]
        assert_equal true, json[:entries].first[:previewable]
        assert_not_includes json[:entries].first.keys, :content
        assert_equal({ path: "identity", name: "identity", type: "directory", depth: 0 }, json[:entries].second)
      end
    end

    test "loads file preview separately" do
      agent = agents(:research_assistant)
      agent.update!(uuid: SecureRandom.uuid_v7)
      dump = Agents::FilesystemDump.new(agent)

      responses = lambda do |*args|
        case args
        when [ "info", "--format", "{{.ServerVersion}}" ]
          ok("27.0.0")
        when [ "volume", "inspect", "#{Agents::Resources.new(agent).volumes.fetch(:identity)}" ]
          ok("[]")
        when [ "run", "--rm", "-v", "#{Agents::Resources.new(agent).volumes.fetch(:identity)}:/identity:ro", "-w", "/identity", "busybox", "head", "-c", "4000", "./soul.md" ]
          ok("# Test Soul\n")
        when [ "run", "--rm", "-v", "#{Agents::Resources.new(agent).volumes.fetch(:identity)}:/identity:ro", "-w", "/identity", "busybox", "wc", "-c", "./soul.md" ]
          ok("12 ./soul.md\n")
        else
          flunk "unexpected docker args: #{args.inspect}"
        end
      end

      dump.stub(:docker_capture, responses) do
        json = dump.file_preview_json("soul.md")
        assert_nil json[:error]
        assert_equal "soul.md", json[:path]
        assert_equal "# Test Soul\n", json[:content]
        assert_equal 12, json[:size_bytes]
      end
    end

    test "rejects unsafe preview paths" do
      agent = agents(:research_assistant)
      agent.update!(uuid: SecureRandom.uuid_v7)

      json = Agents::FilesystemDump.new(agent).file_preview_json("../soul.md")

      assert_equal "invalid path", json[:error]
      assert_equal false, json[:previewable]
    end

    test "private runtime state cannot be previewed through container diagnostics" do
      agent = agents(:research_assistant)
      agent.update!(uuid: SecureRandom.uuid_v7, container_name: "hk-agent-test")

      json = Agents::FilesystemDump.new(agent, target: :container_home)
        .file_preview_json("state/claude/.credentials.json")

      assert_equal "path is private", json[:error]
      assert_equal false, json[:previewable]
    end

    private

    def ok(stdout)
      { stdout: stdout, stderr: "", ok: true }
    end

  end
end
