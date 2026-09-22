require "test_helper"

class Agents::ResidentDirectoryTest < ActiveSupport::TestCase
  test "shared cards contain effort and bounded statistics but no private prompts" do
    agent = agents(:other_account_agent)
    agent.update!(reasoning_effort: "high")
    agent.update_column(:system_prompt, "private resident prompt")
    AgentJournalStatsJob.stub(:request_refresh, nil) do
      cards = Agents::ResidentDirectory.new(agent.account).call
      card = cards.find { |row| row["id"] == agent.to_param }
      assert_equal "high", card.fetch("reasoning_effort")
      assert_equal 14, card.fetch(:activity).size
      assert card.key?(:integrations)
      assert card.key?(:mnemodyne_node_count)
      assert card.key?(:mnemodyne_edge_count)
      refute card.key?("system_prompt")
      refute card.key?("trigger_bearer_token")
      refute_includes cards.to_json, "private resident prompt"
    end
  end

  test "empty external graphs show zero counts and deprecated residents show no counts" do
    agent = agents(:other_account_agent)
    AgentJournalStatsJob.stub(:request_refresh, nil) do
      agent.update_columns(runtime: "external")
      card = Agents::ResidentDirectory.new(agent.account).call.find { |row| row["id"] == agent.to_param }
      assert_equal 0, card.fetch(:mnemodyne_node_count)
      assert_equal 0, card.fetch(:mnemodyne_edge_count)

      agent.update_columns(runtime: "deprecated")
      card = Agents::ResidentDirectory.new(agent.account).call.find { |row| row["id"] == agent.to_param }
      assert_nil card.fetch(:mnemodyne_node_count)
      assert_nil card.fetch(:mnemodyne_edge_count)
    end
  end

end
