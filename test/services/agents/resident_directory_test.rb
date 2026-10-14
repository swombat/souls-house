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

  test "a card carries a failure streak from the second failure, and nothing once a run completes" do
    agent = agents(:other_account_agent)
    chat = agent.account.chats.create!(title: "Streak", manual_responses: true, agents: [ agent ])
    make = ->(state, at) {
      AgentRuntimeInteraction.create!(agent: agent, chat: chat, trigger_kind: "conversation", requested_by: "souls.house",
        session_id: "s", started_at: at - 1.minute, run_id: SecureRandom.uuid, execution_state: state, finished_at: at,
        stderr: "sk-secret-from-stderr")
    }
    card = -> {
      AgentJournalStatsJob.stub(:request_refresh, nil) do
        Agents::ResidentDirectory.new(agent.account).call.find { |row| row["id"] == agent.to_param }
      end
    }
    RunFailureNoticeJob.stub(:perform_later, nil) do
      make.("failed", 30.minutes.ago)
      assert_nil card.().fetch(:failed_runs)

      first_started = 30.minutes.ago - 1.minute
      make.("timed_out", 20.minutes.ago)
      streak = card.().fetch(:failed_runs)
      assert_equal 2, streak[:count]
      assert_in_delta first_started.to_i, Time.iso8601(streak[:since]).to_i, 2
      assert_equal false, streak[:runtime_unavailable]
      refute_includes card.().to_json, "sk-secret"

      make.("completed", 10.minutes.ago)
      assert_nil card.().fetch(:failed_runs)
    end
  end

end
