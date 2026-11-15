require "test_helper"

module Backup
  class FitTest < ActiveSupport::TestCase

    GB = 1.gigabyte

    setup do
      @agent = agents(:research_assistant)
    end

    # A stand-in repository. `sizes` maps how many backups are kept to what
    # they reference. `physical` is what storage holds: it follows the
    # references only once a prune has run, plus any `orphans`.
    def repository(count, sizes, calls: [], orphans: 0)
      list = Array.new(count) { |i| { "id" => "s#{i}", "time" => (count - i).days.ago.iso8601 } }
      pruned_at = count
      run = lambda do |*args|
        calls << args
        case args.first
        when "snapshots" then JSON.generate(list.shuffle)
        when "stats" then JSON.generate("total_size" => sizes.fetch(list.size))
        when "forget" then list.reject! { |snapshot| snapshot["id"] == args[1] } && ""
        when "prune" then (pruned_at = list.size) && (orphans = 0) && ""
        end
      end
      [ run, -> { sizes.fetch(pruned_at) + orphans } ]
    end

    def fit(count, sizes, **options)
      run, physical = repository(count, sizes, **options)
      Fit.new(@agent, run:, physical:).call
    end

    test "a resident's space follows its size, and the write ceiling leaves room for the next full backup" do
      assert_equal 60 * GB, Space.bytes_for(@agent)
      assert_equal({ "small" => 60, "medium" => 60, "large" => 120 }, Space::GB_BY_SIZE)
      # History up to the space, a whole new backup up to the space, and slack.
      assert_operator Space.write_ceiling_bytes(@agent), :>=, 2 * 60 * GB
      assert_equal 135 * GB, Space.write_ceiling_bytes(@agent)
    end

    test "the old flat setting can raise the ceiling but never lower it" do
      with_env("VM_BACKUP_BUDGET_BYTES" => 20.gigabytes.to_s) { assert_equal 135 * GB, Space.write_ceiling_bytes(@agent) }
      with_env("VM_BACKUP_BUDGET_BYTES" => 300.gigabytes.to_s) { assert_equal 300 * GB, Space.write_ceiling_bytes(@agent) }
    end

    test "a repository within its space is recorded and nothing is removed or pruned" do
      calls = []
      history = fit(9, { 9 => 13 * GB }, calls:)

      assert_equal %w[snapshots stats], calls.map(&:first)
      assert_equal 9, history["snapshots"]
      assert_equal 13 * GB, history["stored_bytes"]
      assert_not history["thinned_to_fit"]
      assert_not history["over_space"]
      assert_in_delta 9.days.ago, Time.zone.parse(history["oldest_at"]), 5
      assert_equal history, @agent.reload.backup_history
    end

    test "a resident a little over loses only its oldest backup" do
      calls = []
      history = fit(8, { 8 => 61 * GB, 7 => 58 * GB }, calls:)

      assert_equal [ %w[forget s0] ], calls.select { |args| args.first == "forget" }
      assert_equal 1, calls.count { |args| args.first == "prune" }
      assert_equal 7, history["snapshots"]
      assert_equal 58 * GB, history["stored_bytes"]
      assert history["thinned_to_fit"]
    end

    test "a resident far over loses its oldest backups one at a time until it fits, then prunes once" do
      calls = []
      history = fit(5, { 5 => 90 * GB, 4 => 80 * GB, 3 => 70 * GB, 2 => 40 * GB }, calls:)

      assert_equal [ %w[forget s0], %w[forget s1], %w[forget s2] ], calls.select { |args| args.first == "forget" }
      assert_equal 1, calls.count { |args| args.first == "prune" }
      assert_equal "prune", calls.last.first
      assert_equal 2, history["snapshots"]
      assert_in_delta 2.days.ago, Time.zone.parse(history["oldest_at"]), 5
      assert_not history["over_space"]
    end

    test "the newest backup is never removed, even when it alone is over the space, and that is reported" do
      calls = []
      reported = []
      history = Honeybadger.stub(:notify, ->(error, **options) { reported << [ error.class, options[:fingerprint] ] }) do
        fit(2, { 2 => 150 * GB, 1 => 100 * GB }, calls:)
      end

      assert_equal 1, history["snapshots"]
      assert history["over_space"]
      assert_equal [ %w[forget s0] ], calls.select { |args| args.first == "forget" }
      assert_equal [ [ Fit::OverSpace, "backup-over-space-#{@agent.id}" ] ], reported
    end

    test "data no backup references is pruned when it puts the repository over its space" do
      calls = []
      history = fit(3, { 3 => 30 * GB }, calls:, orphans: 40 * GB)

      assert_empty calls.select { |args| args.first == "forget" }, "no backup is removed for data that is not a backup"
      assert_equal 1, calls.count { |args| args.first == "prune" }
      assert_equal 30 * GB, history["stored_bytes"]
      assert_equal 3, history["snapshots"]
    end

    test "stored is what storage holds, not only what the backups reference" do
      history = fit(3, { 3 => 30 * GB }, orphans: 5 * GB)

      assert_equal 35 * GB, history["stored_bytes"]
      assert_equal 30 * GB, history["referenced_bytes"]
    end

    test "thinning to fit stays said while the repository is still near its space" do
      @agent.update!(backup_history: { "thinned_to_fit" => true })
      assert fit(3, { 3 => 55 * GB })["thinned_to_fit"]
      assert_not fit(3, { 3 => 30 * GB })["thinned_to_fit"]
    end

    test "an unreadable repository size is a failure and records nothing" do
      run = ->(*args) { args.first == "snapshots" ? "[]" : "not json" }
      assert_raises(Fit::Failed) { Fit.new(@agent, run:, physical: -> { nil }).call }
      assert_equal({}, @agent.reload.backup_history)
    end

    test "the hosting tab is given what the repository held, and nothing before the first reading" do
      assert_nil Space.summary(@agent)
      fit(3, { 3 => 5 * GB })

      summary = Space.summary(@agent.reload)
      assert_equal 3, summary[:snapshots]
      assert_equal 5 * GB, summary[:stored_bytes]
      assert_equal 60 * GB, summary[:space_bytes]
      assert_not summary[:thinned_to_fit]
    end

    private

    def with_env(values)
      old = values.keys.to_h { |key| [ key, ENV[key] ] }
      values.each { |key, value| ENV[key] = value }
      yield
    ensure
      old.each { |key, value| ENV[key] = value }
    end

  end
end
