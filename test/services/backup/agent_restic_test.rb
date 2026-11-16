require "test_helper"

module Backup
  class AgentResticTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.uuid = "019f9dbd-4b8b-7c23-80be-770379e5581f"
    end

    test "backs up resident data volumes read-only without private provider state" do
      assert_equal [
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:identity)}:/data/identity:ro",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:chaos)}:/data/chaos:ro",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:repo)}:/data/repo:ro",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:work)}:/data/work:ro"
      ], AgentRestic.backup_mounts(@agent)
    end

    test "restores resident data volumes and the recreated state volume, which receives only transcripts" do
      assert_equal [
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:identity)}:/restore/data/identity",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:chaos)}:/restore/data/chaos",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:repo)}:/restore/data/repo",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:work)}:/restore/data/work",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:state)}:/restore/data/state"
      ], AgentRestic.restore_mounts(@agent)
    end

    test "mounts each present transcript directory read-only through a volume subpath" do
      state = Agents::Resources.new(@agent).volumes.fetch(:state)
      check = "ok claude/projects\nabsent antigravity/.gemini/antigravity-cli/conversations\n" \
        "absent antigravity/.gemini/antigravity-cli/brain\nabsent antigravity/.chaos-conversations\n"
      commands = []
      Open3.stub(:capture3, ->(*command) { commands << command; [ command.include?("sh") ? check : "", "", ok ] }) do
        assert_equal [
          "--mount", "type=volume,src=#{state},dst=/data/state/claude/projects,readonly,volume-subpath=claude/projects"
        ], AgentRestic.transcript_mounts(@agent)
      end
      inspect = commands.last
      assert_includes inspect, "type=volume,src=#{state},dst=/state,readonly"
      assert_includes inspect, "none", "the check runs without a network"
    end

    test "names transcript paths explicitly and never the credential directories around them" do
      assert AgentRestic::TRANSCRIPT_PATHS.none? { |path| path.include?("*") }
      assert_not_includes AgentRestic::TRANSCRIPT_PATHS, "antigravity/.gemini/antigravity-cli"
      assert AgentRestic::TRANSCRIPT_PATHS.none? { |path| path.match?(/credential|oauth|token|tailscale/i) }
    end

    test "a link on a transcript path fails the backup" do
      check = AgentRestic::TRANSCRIPT_PATHS.map { |path| "#{path == 'claude/projects' ? 'link' : 'absent'} #{path}" }.join("\n")
      Open3.stub(:capture3, ->(*command) { [ command.include?("sh") ? check : "", "", ok ] }) do
        error = assert_raises(AgentRestic::TranscriptRefused) { AgentRestic.transcript_mounts(@agent) }
        assert_match "claude/projects", error.message
      end
    end

    test "a file where a transcript directory should be fails the backup" do
      check = AgentRestic::TRANSCRIPT_PATHS.map { |path| "#{path == 'claude/projects' ? 'notdir' : 'absent'} #{path}" }.join("\n")
      Open3.stub(:capture3, ->(*command) { [ command.include?("sh") ? check : "", "", ok ] }) do
        assert_raises(AgentRestic::TranscriptRefused) { AgentRestic.transcript_mounts(@agent) }
      end
    end

    test "a resident without a state volume has no transcripts, and nothing is created" do
      commands = []
      Open3.stub(:capture3, ->(*command) { commands << command; [ "", "Error: No such volume: x", failed ] }) do
        assert_equal [], AgentRestic.transcript_mounts(@agent)
      end
      assert_equal 1, commands.size, "no container is run, so Docker cannot create the volume"
    end

    test "a state volume that cannot be inspected fails the backup instead of dropping transcripts" do
      Open3.stub(:capture3, ->(*_command) { [ "", "Cannot connect to the Docker daemon", failed ] }) do
        assert_raises(AgentRestic::TranscriptRefused) { AgentRestic.transcript_mounts(@agent) }
      end
    end

    test "the check script reports ok, absent, link and notdir from a real filesystem" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "claude/projects"))
        FileUtils.mkdir_p(File.join(root, "antigravity/.gemini"))
        FileUtils.mkdir_p(File.join(root, "elsewhere"))
        File.symlink(File.join(root, "elsewhere"), File.join(root, "antigravity/.gemini/antigravity-cli"))
        File.write(File.join(root, "antigravity/.chaos-conversations"), "")
        script = AgentRestic::TRANSCRIPT_CHECK.gsub("cur=/state", "cur=#{root}")
        out, status = Open3.capture2("sh", "-c", script, "check", *AgentRestic::TRANSCRIPT_PATHS)
        assert status.success?
        assert_equal [
          "ok claude/projects",
          "link antigravity/.gemini/antigravity-cli/conversations",
          "link antigravity/.gemini/antigravity-cli/brain",
          "notdir antigravity/.chaos-conversations"
        ], out.lines.map(&:strip)
      end
    end

    private

    def ok = Struct.new(:success?).new(true)
    def failed = Struct.new(:success?).new(false)

  end
end
