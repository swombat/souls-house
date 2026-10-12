require "test_helper"
require "support/field_swarm_helpers"

class FieldSwarmTest < ActiveSupport::TestCase

  include FieldSwarmHelpers

  VALUATION = "Bob said the business was worth about four million on a good day."

  setup do
    @account = agents(:research_assistant).account
    @account.update!(field_swarm_enabled: true)
    @agent = agents(:research_assistant)
    @board = tagged_note(@account, "Board call", "Opening remarks.\n\n#{VALUATION}\n\nThen lunch.")
    @coffee = tagged_note(@account, "Coffee notes", "We talked about the offer over coffee.")
    @weather = tagged_note(@account, "Weather", "It rained all afternoon.")
    @untagged = @account.whiteboards.create!(name: "Untagged", content: "The offer and the valuation, untagged.")
    @reader = lambda do |user:, **|
      text = material(user)
      if text.include?("worth")
        answer("read_whole", extract: "Bob put it at about four million.", why: "Tone matters.", quotes: [ "worth about four million" ])
      elsif text.include?("coffee")
        answer("extract_enough", extract: "The offer came up.", quotes: [ "talked about the offer" ])
      else
        answer("no")
      end
    end
  end

  def swarm(**options)
    FieldSwarm.new(account: @account, question: "What was the business worth?", tags: [ "research" ], agent: @agent, **options)
  end

  test "each verdict comes back, relevant items first, with a locator on the known passage" do
    result = with_reader(@reader) { swarm.call }
    verdicts = result[:items].map { |item| [ item[:title], item[:verdict] ] }
    assert_equal [ [ "Board call", "read_whole" ], [ "Coffee notes", "extract_enough" ], [ "Weather", "no" ] ], verdicts

    board = result[:items].first
    locator = board[:locators].sole
    assert locator[:verified]
    text = "Opening remarks.\n\n#{VALUATION}\n\nThen lunch."
    assert_equal "worth about four million", text[locator[:offset], locator[:length]]
    assert_equal text.index("worth about four million"), locator[:offset]
    assert_equal "Tone matters.", board[:why]
    assert_equal @board.to_param, board[:id]
    assert board[:api_path].present? && board[:web_path].present?
    assert_nil result[:items].last[:extract]

    summary = result[:summary]
    assert_equal 3, summary[:matched_items]
    assert_equal 3, summary[:completed_reads]
    assert_equal 2, summary[:relevant_items]
    assert summary[:complete]
  end

  test "the grep chooses which tagged items are read" do
    seen = []
    reader = ->(user:, **) { seen << material(user); answer("no") }
    result = with_reader(reader) { swarm(grep: "(?i)OFFER|rained").call }
    assert_equal 2, result[:summary][:matched_items]
    assert_equal 2, seen.size
    assert seen.none? { |text| text.include?("Opening remarks") }
  end

  test "every search and every read is recorded with its reported cost" do
    with_reader(@reader) { swarm.call }
    search = FieldSwarmSearch.sole
    assert_equal @agent, search.agent
    assert_equal "complete", search.status
    assert_equal 3, search.reads.count
    assert_equal BigDecimal("0.000375"), search.cost_usd
    assert_equal 3_000, search.input_tokens
    assert_equal %w[extract_enough no read_whole], search.reads.pluck(:verdict).sort
    assert_equal "0.000125", FieldSwarmSearch.totals[:cost_per_read_usd]
  end

  test "a read that failed is reported as not checked, not as nothing found" do
    reader = lambda do |user:, **|
      raise UtilityInference::RateLimited, "rate limited" if material(user).include?("rained")

      answer("no")
    end
    result = with_reader(reader) { swarm.call }
    weather = result[:items].find { |item| item[:title] == "Weather" }
    assert_equal "unchecked", weather[:verdict]
    assert_not weather[:complete]
    assert_equal "rate_limited", weather[:errors].sole[:status]
    assert_not result[:summary][:complete]
    assert_equal 1, result[:summary][:failed_reads]
    assert_match "weren't checked", result[:notes].join
    assert_equal %w[no no rate_limited], FieldSwarmRead.order(:id).pluck(:status, :verdict).map { |status, verdict| verdict || status }.sort
  end

  test "an answer that isn't the asked-for JSON is a failed read, and an invented quote is unverified" do
    reader = lambda do |user:, **|
      text = material(user)
      if text.include?("worth") then { text: "I think it's relevant.", usage: USAGE, id: "x" }
      elsif text.include?("coffee") then answer("extract_enough", extract: "x", quotes: [ "words nobody said" ])
      else answer("no")
      end
    end
    result = with_reader(reader) { swarm.call }
    assert_equal "unchecked", result[:items].find { |item| item[:title] == "Board call" }[:verdict]
    assert_equal [ { quote: "words nobody said", verified: false } ], result[:items].first[:locators]
    assert_equal 1, FieldSwarmSearch.sole.failed_reads
  end

  test "long items are read in parts, and offsets are into the whole text" do
    filler = "lorem ipsum " * 7_000 # 84,000 characters
    long = tagged_note(@account, "Long transcript", "#{filler}#{VALUATION}")
    reader = lambda do |user:, **|
      text = material(user)
      text.include?("worth") ? answer("extract_enough", extract: "four million", quotes: [ "worth about four million" ]) : answer("no")
    end
    result = with_reader(reader) { swarm(grep: "lorem ipsum").call }
    item = result[:items].sole
    assert_equal long.to_param, item[:id]
    assert_equal 3, item[:parts]
    assert_equal 3, item[:parts_read]
    full = "#{filler}#{VALUATION}"
    locator = item[:locators].sole
    assert_equal full.index("worth about four million"), locator[:offset]
    assert_operator locator[:offset], :>, FieldSwarm::PART_CHARS * 2
  end

  test "the per-search cap stops before an item that doesn't fit, and says so" do
    original = FieldSwarm::MAX_READS
    silence_warnings { FieldSwarm.const_set(:MAX_READS, 2) }
    result = with_reader(@reader) { swarm.call }
    assert_equal 3, result[:summary][:matched_items]
    assert_equal 2, result[:summary][:read_items]
    assert_equal 1, result[:summary][:not_started_items]
    assert_not result[:summary][:complete]
    assert_match "weren't read", result[:notes].join
  ensure
    silence_warnings { FieldSwarm.const_set(:MAX_READS, original) }
  end

  test "off, bad grep, no tag and no question are refused before anything is sent" do
    reader = ->(**) { flunk "no reader should run" }
    with_reader(reader) do
      @account.update!(field_swarm_enabled: false)
      assert_raises(FieldSwarm::Disabled) { swarm.call }
      assert_raises(FieldSwarm::Invalid) { swarm(grep: "(unclosed") }
      assert_raises(FieldSwarm::Invalid) { FieldSwarm.new(account: @account, question: "x", tags: []) }
      assert_raises(FieldSwarm::Invalid) { FieldSwarm.new(account: @account, question: " ", tags: [ "research" ]) }
    end
    assert_equal 0, FieldSwarmSearch.count
  end

  test "parse and locate" do
    assert_nil FieldSwarm.parse("no json here")
    assert_nil FieldSwarm.parse({ verdict: "maybe" }.to_json)
    assert_equal [], FieldSwarm.parse("```json\n#{{ verdict: "no", quotes: [ "x" ] }.to_json}\n```")[:quotes]
    assert_equal [ 4, 7 ], FieldSwarm.locate("say a\n  b c end", "a b c")&.then { |offset, length| [ offset, length ] }
    assert_nil FieldSwarm.locate("abc", "zzz")
  end

end
