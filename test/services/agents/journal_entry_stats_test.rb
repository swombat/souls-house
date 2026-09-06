require "test_helper"
require "tmpdir"

class Agents::JournalEntryStatsTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", container_name: "test-resident")
    @service = Agents::JournalEntryStats.new(@agent)
    @resources = Struct.new(:verify_existing!).new(true)
  end

  test "only a valid aggregate is stored and a failed refresh preserves the count" do
    Agents::Resources.stub(:new, @resources) do
      @service.stub(:capture, { ok: true, stdout: '{"count":42}' }) do
        assert_equal 42, @service.call[:count]
      end
      @agent.journal_entry_stats = { "count" => 21, "measured_at" => 1.day.ago.iso8601 }
      [ { ok: false }, { ok: true, stdout: '{"count":-1}' },
        { ok: true, stdout: "private error" } ].each do |result|
        @service.stub(:capture, result) do
          stats = @service.call
          assert_equal 21, stats["count"]
          assert_equal "unavailable", stats["status"]
          assert_not_includes stats.to_json, "private error"
        end
      end
    end
  end

  test "foreign resources and missing containers never execute the reader" do
    @service.stub(:capture, -> { flunk "must not execute" }) do
      @agent.container_name = nil
      assert_equal "unavailable", @service.call["status"]
      @agent.container_name = "test"
      @agent.sandbox_host = "foreign-host"
      assert_equal "unavailable", @service.call["status"]
    end
  end

  test "reader counts entries not files and ignores fenced headings and symlinks" do
    Dir.mktmpdir do |directory|
      root = Pathname.new(directory)
      root.join("2026-09-05.md").write("# Daily journal\n\n## 09:00 — First\nprivate prose\n## 10:00 — Second\n")
      root.join("2026-09-06.md").write("## Third\n```markdown\n## example\n```\n~~~\n## another example\n~~~\n### subsection\n")
      root.join("README.md").write("## Not an entry\n")
      File.symlink(root.join("2026-09-05.md"), root.join("2026-09-04.md"))
      script = Agents::JournalEntryStats::SCRIPT.sub(Agents::DailyJournalStatus::JOURNAL_DIR, directory)
      stdout, stderr, status = Open3.capture3("python3", "-c", script)
      assert status.success?, stderr
      assert_equal({ "count" => 3 }, JSON.parse(stdout))
      assert_not_includes stdout, "private prose"
    end
  end

  test "an empty journal directory is a measured zero" do
    Dir.mktmpdir do |directory|
      script = Agents::JournalEntryStats::SCRIPT.sub(Agents::DailyJournalStatus::JOURNAL_DIR, directory)
      stdout, _, status = Open3.capture3("python3", "-c", script)
      assert status.success?
      assert_equal 0, JSON.parse(stdout)["count"]
    end
  end

end
