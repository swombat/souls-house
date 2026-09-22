require "test_helper"

class Agents::MemoryHistoryTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:research_assistant)
    @vault = Mnemodyne::Vault.create!(agent: @agent)
    @time = Time.utc(2026, 9, 22, 10)
    @items = []
    @archive = Object.new
    items = @items
    @archive.define_singleton_method(:catalog) { { "status" => "measured", "items" => items } }
    @archive.define_singleton_method(:bodies) { |entries| entries.to_h { |e| [ e["id"], { "body" => "private body", "body_status" => "complete" } ] } }
    @service = Agents::MemoryHistory.new(@agent, archive: @archive)
  end

  test "mixed history is newest first and paginates ties without gaps or duplicates" do
    55.times { |i| add_entry("daily-journals/2026-09-22.md:#{i}") }
    5.times { |i| add_entry("weekly-journals/2026-09-21.md:#{i}", "day_summaries") }
    5.times { |i| @vault.nodes.create!(node_type: "memory", content: "Node #{i}", created_at: @time) }
    first = @service.call
    second = @service.call(cursor: first[:next_cursor])
    assert_equal 50, first[:items].size
    assert_equal 15, second[:items].size
    assert_nil second[:next_cursor]
    all = first[:items] + second[:items]
    assert_equal 65, all.map { |i| i["id"] }.uniq.size
    assert_equal all.sort_by { |i| @service.send(:sort_key, i) }.reverse, all
    assert first[:items].any? { |i| i["kind"] == "nodes" }
    assert first[:items].any? { |i| i["body"] == "private body" }
    refute first[:items].any? { |i| i.key?("fingerprint") }
  end

  test "day summaries precede their day across page boundaries without changing displayed dates" do
    @time = Time.utc(2026, 9, 21)
    add_entry("weekly-journals/2026-09-21.md:000000000001", "day_summaries")
    55.times do |i|
      @time = Time.utc(2026, 9, 21, 23, 59, 59) - i.minutes
      add_entry("daily-journals/2026-09-21.md:#{i}")
    end
    @vault.nodes.create!(node_type: "memory", content: "Late node", created_at: Time.utc(2026, 9, 21, 23, 59, 59))
    @time = Time.utc(2026, 9, 22)
    add_entry("daily-journals/2026-09-22.md:0")
    first = @service.call
    second = @service.call(cursor: first[:next_cursor])
    all = first[:items] + second[:items]
    assert_equal 58, all.size
    assert_equal 58, all.map { |item| item["id"] }.uniq.size
    assert_equal "2026-09-22", all.first["occurred_at"][0, 10]
    assert_equal "day_summaries", all[1]["kind"]
    assert_equal "2026-09-21T00:00:00.000000Z", all[1]["occurred_at"]
    assert_equal "nodes", all[2]["kind"]

    # A page ending on a summary must still include that day's nodes next.
    48.times { |i| add_entry("daily-journals/2026-09-22.md:new#{i}") }
    first = @service.call
    second = @service.call(cursor: first[:next_cursor])
    third = @service.call(cursor: second[:next_cursor])
    assert_equal "day_summaries", first[:items].last["kind"]
    assert_equal "nodes", second[:items].first["kind"]
    assert_equal 106, (first[:items] + second[:items] + third[:items]).map { |i| i["id"] }.uniq.size
  end

  test "node boundary paginates tied UUIDs correctly" do
    55.times { |i| @vault.nodes.create!(node_type: "memory", content: "Node #{i}", created_at: @time) }
    first = @service.call(kinds: [ "nodes" ])
    second = @service.call(kinds: [ "nodes" ], cursor: first[:next_cursor])
    assert_equal 50, first[:items].size
    assert_equal 5, second[:items].size
    assert_empty first[:items].map { |i| i["id"] } & second[:items].map { |i| i["id"] }
  end

  test "cursors are bound to the resident and filters and reject tampering" do
    51.times { |i| add_entry("daily-journals/2026-09-22.md:#{i}") }
    cursor = @service.call[:next_cursor]
    assert_raises(Agents::MemoryHistory::InvalidRequest) { @service.call(cursor: "garbage") }
    assert_raises(Agents::MemoryHistory::InvalidRequest) { @service.call(cursor: cursor, kinds: [ "journals" ]) }
    other = Agents::MemoryHistory.new(agents(:other_account_agent), archive: @archive)
    assert_raises(Agents::MemoryHistory::InvalidRequest) { other.call(cursor: cursor) }
  end

  test "filters select semantic summary kinds and all-off reads no catalog" do
    Agents::MemoryHistory::KINDS.reject { |k| k == "nodes" }.each { |kind| add_entry(kind, kind) }
    assert_equal [ "week_summaries" ], @service.call(kinds: [ "week_summaries" ])[:items].map { |i| i["kind"] }
    @archive.stub(:catalog, -> { flunk "Must not inspect files for all-off or nodes-only" }) do
      assert_empty @service.call(kinds: [])[:items]
      assert_empty @service.call(kinds: [ "nodes" ])[:items]
    end
    assert_raises(Agents::MemoryHistory::InvalidRequest) { @service.call(kinds: [ "secret" ]) }
  end

  test "nodes include pointers and both incoming and outgoing connections without metadata" do
    node = @vault.nodes.create!(node_type: "memory", content: "Memory", description: "Context", source_uris: [ "journal:day#entry" ], created_at: @time)
    anchor = @vault.nodes.create!(node_type: "need", content: "Continuity", created_at: @time - 1.day)
    @vault.edges.create!(source: node, target: anchor, edge_type: "serves", weight: 0.7)
    @vault.edges.create!(source: anchor, target: node, edge_type: "recalls", weight: 0.6)
    item = @service.call(kinds: [ "nodes" ])[:items].first
    assert_equal [ "journal:day#entry" ], item.dig("node", "source_uris")
    assert_equal 2, item["edge_count"]
    assert_equal %w[recalls serves], item["edges"].map { |e| e[:edge_type] }.sort
    refute item["node"].key?("embedding")
    refute item["node"].key?("metadata")
  end

  private

  def add_entry(id, kind = "journals")
    @items << { "id" => id, "kind" => kind, "occurred_at" => @time.iso8601(6), "title" => "Private title", "fingerprint" => "internal" }
  end
end
