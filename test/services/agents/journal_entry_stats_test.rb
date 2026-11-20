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
      script = reader_script(directory)
      stdout, stderr, status = Open3.capture3("python3", "-c", script)
      assert status.success?, stderr
      assert_equal 3, JSON.parse(stdout)["count"]
      assert_not_includes stdout, "private prose"
    end
  end

  test "an empty journal directory is a measured zero" do
    Dir.mktmpdir do |directory|
      script = reader_script(directory)
      stdout, _, status = Open3.capture3("python3", "-c", script)
      assert status.success?
      assert_equal 0, JSON.parse(stdout)["count"]
    end
  end

  # The reader as the runner sends it, pointed at a scratch directory. Its du
  # roots move too: on a resident's own box the real /home/agent volumes exist,
  # and measuring them ran into the script's 10 s timeout.
  def reader_script(directory)
    script = Agents::JournalEntryStats::SCRIPT.sub(Agents::DailyJournalStatus::JOURNAL_DIR, directory)
    roots = '"/home/agent/" + name'
    raise "the reader's volume roots moved" unless script.include?(roots)
    script.sub(roots, "#{directory.to_s.inspect} + \"/\" + name")
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

  # A chosen journal (JqRaEY): one file under memory/, named as argv.
  def with_identity
    Dir.mktmpdir do |directory|
      identity = Pathname.new(directory).join("identity")
      journals = identity.join("memory/daily-journals")
      journals.mkpath
      journals.join("2026-11-20.md").write("## 09:00 daily\n")
      yield identity, reader_script(journals.to_s)
    end
  end

  def read(script, *argv)
    stdout, _, status = Open3.capture3("python3", "-c", script, *argv)
    status.success? ? JSON.parse(stdout)["count"] : :failed
  end

  test "a chosen journal file is counted alone, fence-aware, and only the number comes back" do
    with_identity do |identity, script|
      identity.join("memory/growth-journal.md")
        .write("# Growth\n\n## one\nprivate prose\n```\n## fenced\n```\n## two\n### sub\n## three\n")
      identity.join("memory/notes").mkpath
      identity.join("memory/notes/deep.md").write("## a\n")
      assert_equal 1, read(script)
      assert_equal 3, read(script, "memory/growth-journal.md")
      assert_equal 1, read(script, "memory/notes/deep.md")
      stdout, = Open3.capture3("python3", "-c", script, "memory/growth-journal.md")
      assert_not_includes stdout, "private prose"
    end
  end

  test "a chosen journal that is missing, linked or outside memory/ is unavailable, never zero" do
    with_identity do |identity, script|
      identity.join("memory/real.md").write("## one\n")
      File.symlink(identity.join("memory/real.md"), identity.join("memory/linked.md"))
      identity.join("memory/real-dir").mkpath
      identity.join("memory/real-dir/x.md").write("## one\n")
      File.symlink(identity.join("memory/real-dir"), identity.join("memory/linked-dir"))
      identity.join("other.md").write("## one\n")
      File.mkfifo(identity.join("memory/pipe.md"))
      [ "memory/missing.md", "memory/linked.md", "memory/linked-dir/x.md", "memory/../other.md", "other.md",
        "memory/real-dir", "memory/a b.md", "memory//real.md", "/memory/real.md", "memory/.md/..", "memory/....md/",
        "memory/pipe.md" ].each do |source|
        assert_equal :failed, read(script, source), source
      end
      assert_equal 1, read(script, "memory/real.md")
    end
  end

  test "the local reader passes the chosen journal as one argv value" do
    @agent.update!(journal_source: "memory/growth-journal.md")
    argv = nil
    popen = lambda do |*args, **|
      argv = args
      { ok: true, stdout: '{"count":5,"storage_bytes":null}' }
    end
    Agents::Resources.stub(:new, @resources) do
      Open3.stub(:popen3, popen) { assert_equal 5, @service.call[:count] }
    end
    assert_equal [ "python3", "-c", Agents::JournalEntryStats::SCRIPT, "memory/growth-journal.md" ], argv.last(4)
  end

  test "runner versions: either measures the daily journals; only v2 is asked for a chosen journal" do
    asked = []
    relay = lambda do |_agent, _kind, payload, **|
      asked << payload
      { "count" => 7, "storage_bytes" => 1 }
    end
    enrollment = vm!(facts: { "home_stats" => 1 })
    Agents::RemoteRuntime.stub(:relay!, relay) do
      assert_equal 7, @service.call[:count]
      enrollment.update!(last_facts: { "home_stats" => 2 })
      assert_equal 7, @service.call[:count]

      @agent.update!(journal_source: "memory/growth-journal.md")
      @agent.journal_entry_stats = { "count" => 3 }
      enrollment.update!(last_facts: { "home_stats" => 1 })
      stats = @service.call
      assert_equal "unavailable", stats["status"]
      assert_equal 3, stats["count"]

      enrollment.update!(last_facts: { "home_stats" => 2 })
      assert_equal 7, @service.call[:count]
    end
    assert_equal [ { "container_name" => "test-resident" }, { "container_name" => "test-resident" },
                   { "container_name" => "test-resident", "journal_source" => "memory/growth-journal.md" } ], asked
  end

  test "the chosen-journal rule is one rule" do
    %w[memory/growth-journal.md memory/a/b_c-1.md memory/.hidden.md].each do |source|
      assert Agent.valid_journal_source?(source), source
    end
    [ nil, "", "growth.md", "memory/x.txt", "memory/../x.md", "memory/./x.md", "memory//x.md", "/memory/x.md",
      "memory/x y.md", "memory/...md/..", "memory/#{"a" * 200}.md", "memory/x.md\n" ].each do |source|
      assert_not Agent.valid_journal_source?(source), source.inspect
    end
    @agent.journal_source = "   "
    assert_nil @agent.journal_source
    @agent.journal_source = "memory/../x.md"
    assert_not @agent.valid?
    assert @agent.errors[:journal_source].any?
  end

  test "changing the chosen journal clears the count measured from the old one" do
    @agent.update!(journal_entry_stats: { "count" => 0, "status" => "measured" })
    @agent.update!(name: @agent.name)
    assert_equal 0, @agent.reload.journal_entry_stats["count"]
    @agent.update!(journal_source: "memory/growth-journal.md")
    assert_equal({}, @agent.reload.journal_entry_stats)
  end

  test "a count the old job wrote after the admin loaded the resident is still cleared by the source change" do
    @agent.update_columns(journal_entry_stats: {})
    stale = Agent.find(@agent.id)
    Agent.find(@agent.id).update!(journal_entry_stats: { "count" => 0, "status" => "measured" })
    stale.update!(journal_source: "memory/growth-journal.md")
    assert_equal({}, @agent.reload.journal_entry_stats)
    assert_equal "memory/growth-journal.md", @agent.journal_source
  end

end
