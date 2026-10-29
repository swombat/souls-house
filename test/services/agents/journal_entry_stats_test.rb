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
      @service.stub(:capture, { ok: true, stdout: '{"count":42,"storage_bytes":1024}' }) do
        assert_equal 42, @service.call[:count]
        assert_equal 1024, @service.call[:storage_bytes]
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
      assert_equal 3, JSON.parse(stdout)["count"]
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

  # A resident on its own server has no container on the house host, so its
  # card was "(unavailable)" forever (Alanis, 2026-10-29). Its runner measures.
  def vm!(facts: {})
    placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4343)
    enrollment, token = RunnerEnrollment.mint!(placement:)
    enrollment.confirm_provider_server!(4343)
    enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4343, facts:,
                       nonce: SecureRandom.hex(16))
    enrollment.update!(last_facts: facts)
    @agent.reload
    @service = Agents::JournalEntryStats.new(@agent)
    enrollment
  end

  test "the runner carries the house's journal script byte for byte" do
    runner = Rails.root.join("host-runner/souls_house_runner.py").read
    copy = runner[/^HOME_STATS_SCRIPT = r"""(.*?)"""/m, 1]
    assert copy, "the runner defines HOME_STATS_SCRIPT"
    assert_equal Agents::JournalEntryStats::SCRIPT, copy
    assert_equal Agents::RemoteRuntime::HOME_STATS_VERSION, runner[/^HOME_STATS_VERSION = (\d+)/, 1].to_i
  end

  test "a VM resident is measured by its runner, never by a local docker exec" do
    vm!(facts: { "home_stats" => Agents::RemoteRuntime::HOME_STATS_VERSION })
    asked = []
    relay = lambda do |agent, kind, payload, **|
      asked << [ agent.id, kind, payload ]
      { "count" => 37, "storage_bytes" => 2048 }
    end
    Agents::RemoteRuntime.stub(:relay!, relay) do
      @service.stub(:capture, -> { flunk "must not docker exec on the house host" }) do
        stats = @service.call
        assert_equal "measured", stats[:status]
        assert_equal 37, stats[:count]
        assert_equal 2048, stats[:storage_bytes]
      end
    end
    assert_equal [ [ @agent.id, "home_stats", { "container_name" => "test-resident" } ] ], asked
  end

  test "a VM runner too old to measure is not asked, and the card keeps its last count" do
    vm!
    @agent.journal_entry_stats = { "count" => 9, "measured_at" => 1.day.ago.iso8601 }
    Agents::RemoteRuntime.stub(:relay!, ->(*, **) { flunk "an old runner must not be asked" }) do
      stats = @service.call
      assert_equal "unavailable", stats["status"]
      assert_equal 9, stats["count"]
    end
    assert_equal 0, RunnerCommand.where(kind: "home_stats").count
  end

  test "a malformed or failed runner answer leaves the card unavailable, not wrong" do
    vm!(facts: { "home_stats" => Agents::RemoteRuntime::HOME_STATS_VERSION })
    @agent.journal_entry_stats = { "count" => 9 }
    [ ->(*, **) { { "count" => -1 } }, ->(*, **) { { "count" => "12" } }, ->(*, **) { "nonsense" },
      ->(*, **) { raise Agents::RemoteRuntime::Unavailable, "did not answer" } ].each do |relay|
      Agents::RemoteRuntime.stub(:relay!, relay) do
        stats = @service.call
        assert_equal "unavailable", stats["status"]
        assert_equal 9, stats["count"]
      end
    end
  end

  test "a measured VM answer with no disk figure still shows the count" do
    vm!(facts: { "home_stats" => Agents::RemoteRuntime::HOME_STATS_VERSION })
    Agents::RemoteRuntime.stub(:relay!, ->(*, **) { { "count" => 4, "storage_bytes" => nil } }) do
      stats = @service.call
      assert_equal 4, stats[:count]
      assert_nil stats[:storage_bytes]
    end
  end

end
