require "test_helper"

module Backup
  class FitTest < ActiveSupport::TestCase

    GB = 1.gigabyte

    setup do
      @agent = agents(:research_assistant)
    end

    # A stand-in repository: `sizes` maps how many snapshots are kept to what
    # the repository then stores. forget --keep-last N keeps the newest N.
    def repository(count, sizes, calls: [])
      list = Array.new(count) { |i| { "id" => "s#{i}", "time" => (count - i).days.ago.iso8601 } }
      lambda do |*args|
        calls << args
        case args.first
        when "snapshots" then JSON.generate(list)
        when "stats" then JSON.generate("total_size" => sizes.fetch(list.size))
        when "forget" then list.replace(list.last(Integer(args[args.index("--keep-last") + 1]))) && ""
        end
      end
    end

    test "a resident's space follows its size, and a resident with no size gets the default" do
      assert_equal 60 * GB, Space.bytes_for(@agent)
      assert_equal({ "small" => 60, "medium" => 60, "large" => 120 }, Space::GB_BY_SIZE)
      assert_equal 90 * GB, Space.write_ceiling_bytes(@agent)
    end

    test "a repository within its space is recorded and nothing is removed" do
      calls = []
      history = Fit.new(@agent, run: repository(9, { 9 => 13 * GB }, calls:)).call

      assert_equal %w[snapshots stats], calls.map(&:first)
      assert_equal 9, history["snapshots"]
      assert_equal 13 * GB, history["stored_bytes"]
      assert_not history["thinned_to_fit"]
      assert_not history["over_space"]
      assert_in_delta 9.days.ago, Time.zone.parse(history["oldest_at"]), 5
      assert_equal history, @agent.reload.backup_history
    end

    test "a repository over its space loses older history, newest kept, until it fits" do
      calls = []
      history = Fit.new(@agent, run: repository(8, { 8 => 90 * GB, 4 => 70 * GB, 2 => 40 * GB }, calls:)).call

      assert_equal [ [ "forget", "--group-by", "", "--keep-last", "4", "--prune" ],
        [ "forget", "--group-by", "", "--keep-last", "2", "--prune" ] ], calls.select { |args| args.first == "forget" }
      assert_equal 2, history["snapshots"]
      assert history["thinned_to_fit"]
      assert_not history["over_space"]
      assert_in_delta 2.days.ago, Time.zone.parse(history["oldest_at"]), 5
    end

    test "the newest backup is never removed, even when it alone is over the space" do
      calls = []
      history = Fit.new(@agent, run: repository(2, { 2 => 150 * GB, 1 => 100 * GB }, calls:)).call

      assert_equal 1, history["snapshots"]
      assert history["over_space"]
      assert_equal 1, calls.count { |args| args.first == "forget" }
    end

    test "thinning to fit stays said while the repository is still near its space" do
      @agent.update!(backup_history: { "thinned_to_fit" => true })
      assert Fit.new(@agent, run: repository(3, { 3 => 55 * GB })).call["thinned_to_fit"]
      assert_not Fit.new(@agent, run: repository(3, { 3 => 30 * GB })).call["thinned_to_fit"]
    end

    test "an unreadable repository size is a failure and records nothing" do
      run = ->(*args) { args.first == "snapshots" ? "[]" : "not json" }
      assert_raises(Fit::Failed) { Fit.new(@agent, run:).call }
      assert_equal({}, @agent.reload.backup_history)
    end

    test "the hosting tab is given what the repository held, and nothing before the first reading" do
      assert_nil Space.summary(@agent)
      Fit.new(@agent, run: repository(3, { 3 => 5 * GB })).call

      summary = Space.summary(@agent.reload)
      assert_equal 3, summary[:snapshots]
      assert_equal 5 * GB, summary[:stored_bytes]
      assert_equal 60 * GB, summary[:space_bytes]
      assert_not summary[:thinned_to_fit]
    end

  end
end
