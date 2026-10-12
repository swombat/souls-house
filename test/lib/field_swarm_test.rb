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


  def with_limits(deadline:, min_read_time: 0.05, read_timeout: 30)
    previous = [ FieldSwarm.deadline, FieldSwarm.min_read_time, FieldSwarm.read_timeout ]
    FieldSwarm.deadline, FieldSwarm.min_read_time, FieldSwarm.read_timeout = deadline, min_read_time, read_timeout
    yield
  ensure
    FieldSwarm.deadline, FieldSwarm.min_read_time, FieldSwarm.read_timeout = previous
  end

  def with_const(name, value)
    original = FieldSwarm.const_get(name)
    silence_warnings { FieldSwarm.const_set(name, value) }
    yield
  ensure
    silence_warnings { FieldSwarm.const_set(name, original) }
  end

  def elapsed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
    Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end

  test "the deadline is wall-clock: a reader that is still going is cut off and counted as possibly billed" do
    # A slow trickle of bytes never trips a socket timeout; a reader that
    # just keeps going stands in for it.
    slow = ->(**) { sleep 10; answer("no") }
    result = nil
    took = elapsed { with_limits(deadline: 0.5) { with_reader(slow) { result = swarm.call } } }
    assert_operator took, :<, 1.25, "each read bounds itself; the backstop is later"
    assert_equal %w[timed_out timed_out timed_out], FieldSwarmRead.order(:id).pluck(:status)
    assert FieldSwarmRead.all.all?(&:cost_uncertain)
    search = FieldSwarmSearch.sole
    assert_equal 3, search.uncertain_cost_reads
    assert_equal 3, search.failed_reads
    assert result[:items].all? { |item| item[:verdict] == "unchecked" }
    assert_not result[:summary][:complete]
  end

  test "a reader that swallows the timeout is stopped at the deadline anyway" do
    stubborn = lambda do |**|
      begin
        sleep 10
      rescue Exception # rubocop:disable Lint/RescueException
        sleep 10
      end
      answer("no")
    end
    took = elapsed { with_limits(deadline: 0.5) { with_reader(stubborn) { swarm.call } } }
    assert_operator took, :<, 4
    assert_equal %w[timed_out timed_out timed_out], FieldSwarmRead.order(:id).pluck(:status)
    assert_equal 3, FieldSwarmSearch.sole.uncertain_cost_reads
  end

  test "an unusable answer keeps its reported cost, and a sent call with no cost is uncertain, never free" do
    reader = lambda do |user:, **|
      text = material(user)
      if text.include?("worth") then { text: nil, usage: USAGE, id: "gen-empty" }
      elsif text.include?("coffee") then answer("no", usage: nil).merge(id: nil)
      else raise UtilityInference::RateLimited, "rate limited"
      end
    end
    with_reader(reader) { swarm.call }
    empty = FieldSwarmRead.find_by!(upstream_id: "gen-empty")
    assert_equal "failed", empty.status
    assert_equal BigDecimal("0.000125"), empty.cost_usd
    assert_equal 1_000, empty.input_tokens
    assert_not empty.cost_uncertain
    no_usage = FieldSwarmRead.find_by!(status: "read")
    assert_nil no_usage.cost_usd
    assert no_usage.cost_uncertain
    assert_not FieldSwarmRead.find_by!(status: "rate_limited").cost_uncertain, "a 429 isn't billed"
    search = FieldSwarmSearch.sole
    assert_equal 1, search.uncertain_cost_reads
    assert_equal BigDecimal("0.000125"), search.cost_usd
  end

  test "admission counts and reserves under a lock on the account row, and the daily cap holds" do
    assert_queries_match(/FROM "accounts".*FOR UPDATE/m) { with_reader(@reader) { swarm.call } }
    with_const(:MAX_SEARCHES_PER_ACCOUNT_PER_DAY, 2) do
      with_reader(@reader) { swarm.call }
      assert_raises(FieldSwarm::LimitReached) { with_reader(@reader) { swarm.call } }
    end
    assert_equal 2, FieldSwarmSearch.count
  end

  test "a search refused before any reader is sent doesn't use up one of the day's searches" do
    search = swarm
    search.define_singleton_method(:candidates) { raise FieldSwarm::Invalid, "grep took too long" }
    assert_raises(FieldSwarm::Invalid) { with_reader(->(**) { flunk "no reader" }) { search.call } }
    assert_equal 0, FieldSwarmSearch.count
  end

  test "the read cap holds against the text as loaded, even if bodies grew after they were measured" do
    tagged_note(@account, "Grew", "lorem ipsum " * 7_000) # three parts once loaded
    search = swarm
    # As if every body were one character when the candidates were counted.
    search.define_singleton_method(:candidates) { super().map { |row| row.merge(chars: 1) } }
    sent = Queue.new
    reader = ->(user:, **) { sent << user; answer("no") }
    result = with_const(:MAX_READS, 2) { with_reader(reader) { search.call } }
    assert_operator sent.size, :<=, 2
    assert_operator FieldSwarmSearch.sole.planned_reads, :<=, 2
    assert_operator result[:summary][:not_started_items], :>=, 1
    assert_not result[:summary][:complete]
  end

  test "a passage on the seam between two parts is whole in one of them" do
    phrase = "worth four million"
    tagged_note(@account, "Seam", "#{"x" * 39_995}#{phrase} and more", tag: "seam")
    seen = Queue.new
    reader = ->(user:, **) { seen << material(user); answer("no") }
    with_reader(reader) { FieldSwarm.new(account: @account, question: "q", tags: [ "seam" ]).call }
    materials = Array.new(seen.size) { seen.pop }
    assert_equal 2, materials.size
    assert materials.any? { |text| text.include?(phrase) }, "no reader saw the whole phrase"
  end

  test "locators say which field the quote is in and where, as well as the offset into the item's text" do
    note = tagged_note(@account, "Both", "actual content", tag: "fields")
    note.update_columns(summary: "summary")
    reader = ->(**) { answer("extract_enough", extract: "it", quotes: [ "actual content" ]) }
    result = with_reader(reader) { FieldSwarm.new(account: @account, question: "q", tags: [ "fields" ]).call }
    locator = result[:items].sole[:locators].sole
    assert_equal 9, locator[:offset]
    assert_equal "content", locator[:field]
    assert_equal 0, locator[:field_offset]
    assert_equal "actual content", note.reload.content[locator[:field_offset], locator[:length]]
  end

  test "the text the readers get is the text Field search reads" do
    note = tagged_note(@account, "Composed", "body text")
    note.update_columns(summary: "a summary")
    body = ActiveRecord::Base.connection.select_value(
      "SELECT #{FieldSearch::SOURCES["note"][:body]} FROM whiteboards WHERE id = #{note.id}")
    assert_equal body, FieldSwarm.text_for("note", note.reload).text
    recording = Struct.new(:note, :notes, :transcript_text, :status).new(nil, "notes", "words", "processing")
    assert_equal "notes", FieldSwarm.text_for("recording", recording).text, "a transcript counts once it is ready"
    recording.status = "ready"
    assert_equal [ "transcript_text", 2 ], FieldSwarm.text_for("recording", recording).field_at(9)
  end

  test "malformed relevant answers are failed reads, not empty successes" do
    assert_nil FieldSwarm.parse({ verdict: "extract_enough" }.to_json)
    assert_nil FieldSwarm.parse({ verdict: "read_whole", extract: 5, quotes: 7 }.to_json)
    assert_nil FieldSwarm.parse({ verdict: "read_whole", extract: "x", quotes: [ 1 ] }.to_json)
    assert_nil FieldSwarm.parse({ verdict: "extract_enough", extract: "x", quotes: [] }.to_json)
    assert_nil FieldSwarm.parse({ verdict: "extract_enough", extract: " ", quotes: [ "q" ] }.to_json)
    assert_nil FieldSwarm.parse({ verdict: "no", why: 3 }.to_json)
    assert_equal "no", FieldSwarm.parse({ verdict: "no" }.to_json)[:verdict]
    assert_equal [ "q" ], FieldSwarm.parse({ verdict: "read_whole", extract: "x", quotes: [ "q" ] }.to_json)[:quotes]
  end

end
