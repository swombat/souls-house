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

    test "restores resident data volumes without overwriting private provider state" do
      assert_equal [
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:identity)}:/restore/data/identity",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:chaos)}:/restore/data/chaos",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:repo)}:/restore/data/repo",
        "-v", "#{Agents::Resources.new(@agent).volumes.fetch(:work)}:/restore/data/work"
      ], AgentRestic.restore_mounts(@agent)
    end

  end
end
