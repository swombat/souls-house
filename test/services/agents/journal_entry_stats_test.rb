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
        # Disk use is Agents::HomeStorage's now; a figure here is ignored.
        assert_not @service.call.key?(:storage_bytes)
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
    with_home do |home, script|
      root = home.join("memory/daily-journals")
      root.join("2026-09-05.md").write("# Daily journal\n\n## 09:00 — First\nprivate prose\n## 10:00 — Second\n")
      root.join("2026-09-06.md").write("## Third\n```markdown\n## example\n```\n~~~\n## another example\n~~~\n### subsection\n")
      root.join("README.md").write("## Not an entry\n")
      File.symlink(root.join("2026-09-05.md"), root.join("2026-09-04.md"))
      stdout, stderr, status = Open3.capture3("python3", "-c", script)
      assert status.success?, stderr
      assert_equal 3, JSON.parse(stdout)["count"]
      assert_not_includes stdout, "private prose"
    end
  end

  test "an empty journal directory is a measured zero, and so is a home that has not started one" do
    with_home do |home, script|
      assert_equal 0, read(script)
      FileUtils.remove_entry(home.join("memory"))
      assert_equal 0, read(script)
    end
  end

  # The reader as the runner sends it, pointed at a scratch home.
  def reader_script(home)
    Agents::JournalEntryStats::SCRIPT.sub('HOME = "/home/agent/identity"', "HOME = #{home.to_s.to_json}")
  end

  def with_home
    Dir.mktmpdir do |directory|
      home = Pathname.new(directory).join("identity")
      home.join("memory/daily-journals").mkpath
      yield home, reader_script(home)
    end
  end

  def declare(home, journal)
    home.join("resident-home.json").write({ "format" => "souls-home/v1", "journal" => journal }.to_json)
  end

  def read(script, *argv)
    stdout, _, status = Open3.capture3("python3", "-c", script, *argv)
    return :failed unless status.success?

    measured = JSON.parse(stdout)
    measured.key?("count") ? measured["count"] : measured["status"]
  end

  # JLmxrY: the resident declares its journal in resident-home.json, and one
  # rule reads whatever the path names (journal_rule.py).
  test "every declared shape is counted by the one rule" do
    with_home do |home, script|
      home.join("memory/daily-journals/2026-11-20.md").write("## 09:00 one\n## 10:00 two\n")
      assert_equal 2, read(script), "no manifest: memory/daily-journals"
      home.join("resident-home.json").write({ "format" => "souls-home/v1" }.to_json)
      assert_equal 2, read(script), "a manifest without the key: the default"

      # One file per entry in day folders, beside older day files.
      journal = home.join("shared/memory/daily-journals")
      journal.join("2026-11-21").mkpath
      journal.join("2026-11-22").mkpath
      journal.join("2026-11-20.md").write("## 09:00 old one\n```\n## fenced\n```\n## 10:00 old two\n")
      journal.join("2026-11-21/0900-morning.md").write("## 09:00 morning\n\n## What happened\n## What is open\nprose\n")
      journal.join("2026-11-21/1400.md").write("no heading at all, still one entry\n")
      journal.join("2026-11-21/empty.md").write("")
      journal.join("2026-11-21/blank.md").write("\n  \n")
      journal.join("2026-11-21/.gitkeep").write("")
      journal.join("2026-11-21/.draft.md").write("## hidden\n")
      journal.join("2026-11-21/README.md").write("## a guide\n")
      journal.join("2026-11-21/notes.txt").write("## not markdown\n")
      journal.join("2026-11-21.md").write("## 23:00 same day, older file\n")
      journal.join("2026-11-22/one.md").write("## one\n")
      journal.join("2026-11-22/nested").mkpath
      journal.join("2026-11-22/nested/deep.md").write("## too deep\n")
      journal.join("README.md").write("## guide\n")
      journal.join(".gitkeep").write("")
      journal.join("index.md").write("## not a day\n")
      journal.join("archive").mkpath
      journal.join("archive/2026-01-01.md").write("## swept up?\n")
      File.symlink(journal.join("2026-11-22/one.md"), journal.join("2026-11-22/linked.md"))
      File.symlink(journal.join("2026-11-22"), journal.join("2026-11-23"))
      declare(home, { "path" => "shared/memory/daily-journals" })
      # 2 (day file) + 2 (day folder) + 1 (same-day file) + 1 (next day folder)
      assert_equal 6, read(script)

      declare(home, { "path" => "shared/memory/daily-journals/2026-11-20.md" })
      assert_equal 2, read(script), "a single file: its headings"
      declare(home, { "path" => "memory/daily-journals" })
      assert_equal 2, read(script)
    end
  end

  test "journal false is not shared, whatever an admin chose" do
    with_home do |home, script|
      home.join("memory/growth.md").write("## one\n")
      declare(home, false)
      assert_equal "not_shared", read(script)
      assert_equal "not_shared", read(script, "memory/growth.md")
    end
  end

  test "only the home's declaration names the journal; a path passed from outside is never read" do
    with_home do |home, script|
      home.join("memory/growth.md").write("## one\n## two\n## three\n")
      home.join("journal").mkpath
      home.join("journal/2026-11-20.md").write("## one\n")
      assert_equal 0, read(script, "memory/growth.md")
      declare(home, { "path" => "journal" })
      assert_equal 1, read(script, "memory/growth.md")
      declare(home, { "path" => "memory/growth.md" })
      assert_equal 3, read(script)
    end
  end

  test "a declared journal that is linked, escapes, is missing or is malformed is unavailable, never zero" do
    with_home do |home, script|
      home.join("journal").mkpath
      home.join("journal/2026-11-20.md").write("## one\n")
      home.join("one.md").write("## one\n")
      File.symlink(home.join("journal"), home.join("linked"))
      File.symlink(home.join("one.md"), home.join("linked.md"))
      home.join("via").mkpath
      File.symlink(home.join("journal"), home.join("via/inner"))
      outside = Pathname.new(Dir.mktmpdir)
      outside.join("2026-11-20.md").write("## escaped\n")
      File.symlink(outside, home.join("escape"))
      home.join("notes.txt").write("## one\n")
      File.mkfifo(home.join("pipe.md"))
      [ { "path" => "linked" }, { "path" => "linked.md" }, { "path" => "via/inner" }, { "path" => "escape" },
        { "path" => "../identity/journal" }, { "path" => "/journal" }, { "path" => "journal/" }, { "path" => "journal//x" },
        { "path" => "./journal" }, { "path" => "missing" }, { "path" => "notes.txt" }, { "path" => "pipe.md" },
        { "path" => "" }, { "path" => 7 }, { "path" => "journal", "share" => "count" }, {}, true, "journal", nil, [] ].each do |journal|
        declare(home, journal)
        assert_equal :failed, read(script), journal.inspect
      end
      declare(home, { "path" => "journal" })
      assert_equal 1, read(script)
      FileUtils.remove_entry(outside)
    end
  end

  test "a linked or malformed manifest is unavailable, not the default" do
    with_home do |home, script|
      home.join("memory/daily-journals/2026-11-20.md").write("## one\n")
      home.join("elsewhere.json").write({ "journal" => false }.to_json)
      File.symlink(home.join("elsewhere.json"), home.join("resident-home.json"))
      assert_equal :failed, read(script)
      home.join("resident-home.json").delete
      [ "not json", "[1]", "\"journal\"" ].each do |text|
        home.join("resident-home.json").write(text)
        assert_equal :failed, read(script), text
      end
      home.join("resident-home.json").delete
      assert_equal 1, read(script)
    end
  end

  test "an unreadable day file fails the count instead of shrinking it" do
    with_home do |home, script|
      day = home.join("memory/daily-journals/2026-11-20.md")
      day.write("## one\n")
      day.chmod(0o000)
      skip "running as root reads anything" if File.readable?(day)
      assert_equal :failed, read(script)
    ensure
      day&.chmod(0o644)
    end
  end

  test "the house reports not shared, and keeps no old count beside it" do
    @agent.journal_entry_stats = { "count" => 12, "status" => "measured" }
    Agents::Resources.stub(:new, @resources) do
      @service.stub(:capture, { ok: true, stdout: '{"status": "not_shared"}' }) do
        stats = @service.call
        assert_equal "not_shared", stats[:status]
        assert_not stats.key?(:count)
      end
      @service.stub(:capture, { ok: true, stdout: '{"status": "shared?"}' }) do
        assert_equal "unavailable", @service.call["status"]
      end
    end
  end

  # A walk of a 100 GB home outlasted the count's budget and left the disk
  # figure empty for the largest homes (jZWPXJ): the count never walks.
  test "the count script does not walk the disk" do
    assert_no_match(/\bdu\b|subprocess/, Agents::JournalEntryStats::SCRIPT)
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
        assert_not stats.key?(:storage_bytes), "an older runner's disk figure is not the card's"
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

  test "runner versions: only a runner that reads the home's declaration is asked for a count" do
    asked = []
    relay = lambda do |_agent, _kind, payload, **|
      asked << payload
      { "count" => 7 }
    end
    enrollment = vm!(facts: { "home_stats" => 1 })
    @agent.journal_entry_stats = { "count" => 3 }
    Agents::RemoteRuntime.stub(:relay!, relay) do
      [ 1, 2, 3 ].each do |version|
        enrollment.update!(last_facts: { "home_stats" => version })
        stats = @service.call
        assert_equal "unavailable", stats["status"], "v#{version} would count memory/daily-journals"
        assert_equal 3, stats["count"]
      end
      enrollment.update!(last_facts: { "home_stats" => 4 })
      assert_equal 7, @service.call[:count]
    end
    assert_equal [ { "container_name" => "test-resident" } ], asked
  end

  test "a VM runner's not shared reaches the card" do
    vm!(facts: { "home_stats" => Agents::RemoteRuntime::HOME_STATS_VERSION })
    Agents::RemoteRuntime.stub(:relay!, ->(*, **) { { "status" => "not_shared" } }) do
      assert_equal "not_shared", @service.call[:status]
    end
  end

end
