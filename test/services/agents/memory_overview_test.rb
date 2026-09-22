require "test_helper"

class Agents::MemoryOverviewTest < ActiveSupport::TestCase
  test "returns fourteen zero-filled days and scoped creation counts without private contents" do
    agent = agents(:research_assistant)
    vault = Mnemodyne::Vault.create!(agent: agent)
    first = vault.nodes.create!(node_type: "memory", content: "private node", created_at: Time.utc(2026, 9, 9))
    last = vault.nodes.create!(node_type: "need", content: "private anchor", is_dormant: true, created_at: Time.utc(2026, 9, 22, 23, 59))
    vault.nodes.create!(node_type: "memory", content: "old", created_at: Time.utc(2026, 9, 8, 23, 59), updated_at: Time.utc(2026, 9, 22))
    vault.edges.create!(source: first, target: last, edge_type: "serves", created_at: Time.utc(2026, 9, 20))
    other = Mnemodyne::Vault.create!(agent: agents(:other_account_agent))
    other.nodes.create!(node_type: "memory", content: "other resident", created_at: Time.utc(2026, 9, 22))
    archive = Struct.new(:overview).new({ "status" => "measured", "count" => 17, "daily_counts" => { "2026-09-21" => 3 }, "items" => [ "DO NOT LEAK" ] })
    result = Agents::MemoryOverview.new(agent, archive: archive, today: Date.new(2026, 9, 22)).call
    assert_equal 14, result[:days].size
    assert_equal "2026-09-09", result[:days].first[:date]
    assert_equal 1, result[:days].first[:nodes]
    assert_equal 1, result[:days].last[:nodes]
    assert_equal 3, result[:days][-2][:journals]
    assert_equal 1, result[:days][-3][:edges]
    assert_equal 3, result[:node_count]
    assert_equal 17, result[:journals]["count"]
    refute_match(/private|LEAK|other resident/, result.to_json)
  end
end
