require "test_helper"
require "tmpdir"
require "open3"

class Agents::MemoryArchiveTest < ActiveSupport::TestCase

  setup do
    @home = Pathname.new(Dir.mktmpdir).realpath
    @root = @home.join("memory")
    %w[daily weekly monthly yearly].each { |layer| @root.join("#{layer}-journals").mkpath }
  end

  teardown { FileUtils.remove_entry(@home) }

  test "splits entries outside fences and returns only aggregates for overview" do
    write("daily-journals/2026-09-22.md", "# Journal\n## 09:10 — Private first\nsecret α\n```md\n## fake\n```\n## 10:20 — Second\nother secret\n")
    overview = run_reader(mode: "overview")
    assert_equal 2, overview["count"]
    assert_equal({ "2026-09-22" => 2 }, overview["daily_counts"])
    refute_match(/Private|secret|items|path/, overview.to_json)
    catalog = run_reader(mode: "catalog")
    assert_equal 2, catalog["items"].size
    refute_includes catalog.to_json, "secret"
    bodies = run_reader(mode: "bodies", items: catalog["items"])
    assert_includes bodies.values.first["body"], "secret α"
    refute_includes bodies.values.first["body"], "other secret"
    assert_equal "2026-09-22T10:20:00.000000Z", catalog["items"].last["occurred_at"]
  end

  test "empty title-only files are not entries and offsets retain append order for tied times" do
    write("daily-journals/2026-09-20.md", "# Daily Journal: 2026-09-20\n\n")
    write("daily-journals/2026-09-22.md", "## First\n" + "x" * 100 + "\n## Second\n" + "y" * 1000 + "\n## Third\nbody")
    items = run_reader(mode: "catalog")["items"]
    assert_equal 3, items.size
    assert_equal %w[Third Second First], items.sort_by { |item| item["id"] }.reverse.map { |item| item["title"] }
  end

  test "maps summary layers to their semantic kinds and dates" do
    write("weekly-journals/2026-09-14.md", "## 2026-09-15 (Tuesday)\nDay one\n## 2026-09-16 (Wednesday)\nDay two")
    write("monthly-journals/2026-09.md", "## Week of 2026-09-14 (Monday-Sunday)\nWeek")
    write("yearly-journals/2026.md", "## 2026-08 (August)\nMonth")
    items = run_reader(mode: "catalog")["items"]
    assert_equal %w[day_summaries day_summaries week_summaries month_summaries], items.map { |i| i["kind"] }
    assert_equal %w[2026-09-15 2026-09-16 2026-09-14 2026-08-01], items.map { |i| i["occurred_at"][0, 10] }
  end

  test "ignores guides, preserves headingless entries and refuses symlinks" do
    write("daily-journals/README.md", "## not a memory")
    write("daily-journals/2026-09-20.md", "A headingless memory")
    File.symlink(@root.join("daily-journals/2026-09-20.md"), @root.join("daily-journals/2026-09-21.md"))
    result = run_reader(mode: "catalog")
    # A link is not a file the rule reads, here or on the card.
    assert_equal "measured", result["status"]
    assert_equal 1, result["count"]
    assert_equal "Untitled entry", result["items"].first["title"]
  end

  test "detects changed files instead of reading stale offsets" do
    write("daily-journals/2026-09-22.md", "## First\noriginal")
    items = run_reader(mode: "catalog")["items"]
    write("daily-journals/2026-09-22.md", "## Other\nchanged")
    result = run_reader(mode: "bodies", items: items)
    assert_equal "changed", result.values.first["body_status"]
    refute result.values.first.key?("body")
  end

  test "truncation is explicit and invalid dates do not crash the scan" do
    write("daily-journals/2026-09-22.md", "## 99:99 — malformed time\n" + "x" * 70_000)
    write("daily-journals/2026-99-99.md", "## Invalid date")
    catalog = run_reader(mode: "catalog")
    assert_equal "partial", catalog["status"]
    # Counted like the card counts it; only the undatable one has no item.
    assert_equal 2, catalog["count"]
    assert_equal 1, catalog["items"].size
    body = run_reader(mode: "bodies", items: catalog["items"]).values.first
    assert_equal "truncated", body["body_status"]
    assert_equal 65_536, body["body"].bytesize
  end

  test "refuses symlink ancestors, and paths outside the journal layers" do
    FileUtils.remove_entry(@root.join("weekly-journals"))
    File.symlink(@root.join("daily-journals"), @root.join("weekly-journals"))
    _out, _err, status = execute(mode: "catalog")
    refute status.success?
    # Complete, correctly fingerprinted selections, so only the path check can refuse them.
    @root.join("people").mkpath
    write("people/anna.md", "private, not a journal")
    write("daily-journals/notes.txt", "private, not a day file")
    @root.join("weekly-journals").delete
    @root.join("weekly-journals").mkpath
    write("daily-journals/2026-09-22.md", "## ordinary\nshown\n")
    @home.join("resident-home.json").write("{}")
    good = run_reader(mode: "catalog")["items"].find { |item| item["path"] == "memory/daily-journals/2026-09-22.md" }
    foreign = %w[memory/people/anna.md memory/daily-journals/notes.txt resident-home.json memory/../memory/people/anna.md].map do |path|
      data = @home.join(path).binread
      { id: path, path: path, fingerprint: Digest::SHA256.hexdigest(data), start: 0, end: data.bytesize }
    end
    bodies = run_reader(mode: "bodies", items: foreign + [ good ])
    foreign.each { |item| assert_equal({ "body_status" => "unavailable" }, bodies.fetch(item[:id]), item[:path]) }
    assert_equal "complete", bodies.fetch(good["id"])["body_status"], "a refusal is the item's alone"
    refute_includes bodies.to_json, "private"
  end

  test "a declared journal of day folders is read by the card's rule, one entry per file" do
    journal = @home.join("shared/memory/daily-journals")
    journal.join("2026-11-21").mkpath
    journal.join("2026-11-20.md").write("## 09:00 old one\nold prose\n## 10:00 old two\n")
    journal.join("2026-11-21/0900-morning.md").write("## 09:00 morning\nsecret\n## What happened\n## What is open\n")
    journal.join("2026-11-21/later.md").write("no heading\n")
    journal.join("2026-11-21/README.md").write("## guide\n")
    journal.join("2026-11-21/.gitkeep").write("")
    write("daily-journals/2026-11-19.md", "## not the declared journal\n")
    write("weekly-journals/2026-11-16.md", "## 2026-11-17 (Tuesday)\nsummary\n")
    declare({ "path" => "shared/memory/daily-journals" })

    overview = run_reader(mode: "overview")
    assert_equal 4, overview["count"]
    assert_equal({ "2026-11-20" => 2, "2026-11-21" => 2 }, overview["daily_counts"])

    catalog = run_reader(mode: "catalog")
    journals = catalog["items"].select { |item| item["kind"] == "journals" }
    assert_equal [ "later", "09:00 morning", "10:00 old two", "09:00 old one" ].sort, journals.map { |item| item["title"] }.sort
    morning = journals.find { |item| item["title"] == "09:00 morning" }
    assert_equal "shared/memory/daily-journals/2026-11-21/0900-morning.md", morning["path"]
    assert_equal "2026-11-21T09:00:00.000000Z", morning["occurred_at"]
    assert_equal 1, catalog["items"].count { |item| item["kind"] == "day_summaries" }, "summary layers stay where they were"

    body = run_reader(mode: "bodies", items: [ morning ]).fetch(morning["id"])
    assert_equal "complete", body["body_status"]
    assert_includes body["body"], "## What is open", "the whole file is the one entry"
  end

  test "an entry file with an ordinary spaced name round-trips beside another" do
    journal = @home.join("journal/2026-11-21")
    journal.mkpath
    journal.join("morning note.md").write("## 09:00 morning\nspaced body\n")
    journal.join("later.md").write("## 18:00 later\nplain body\n")
    journal.join("café ☕.md").write("## 20:00 unicode\nunicode body\n")
    declare({ "path" => "journal" })
    catalog = run_reader(mode: "catalog")
    assert_equal 3, catalog["count"]
    bodies = run_reader(mode: "bodies", items: catalog["items"])
    assert_equal %w[complete complete complete], bodies.values.map { |body| body["body_status"] }
    assert_includes bodies.to_json, "spaced body"
  end

  test "journal false closes the count and every journal layer" do
    write("daily-journals/2026-11-20.md", "## one\nprivate\n")
    write("weekly-journals/2026-11-16.md", "## 2026-11-17 (Tuesday)\nprivate\n")
    catalog = run_reader(mode: "catalog")
    declare(false)
    overview = run_reader(mode: "overview")
    assert_equal "not_shared", overview["status"]
    assert_nil overview["count"]
    closed = run_reader(mode: "catalog")
    assert_equal [], closed["items"]
    bodies = run_reader(mode: "bodies", items: catalog["items"])
    assert bodies.values.all? { |body| body == { "body_status" => "unavailable" } }
    refute_includes bodies.to_json, "private"
  end

  test "bodies are only read from the journal the home declares" do
    write("daily-journals/2026-11-20.md", "## one\nprivate default\n")
    @home.join("journal").mkpath
    @home.join("journal/2026-11-20.md").write("## one\nshared\n")
    data = @root.join("daily-journals/2026-11-20.md").binread
    stale = { id: "x", path: "memory/daily-journals/2026-11-20.md", fingerprint: Digest::SHA256.hexdigest(data), start: 0, end: data.bytesize }
    declare({ "path" => "journal" })
    out, err, status = execute(mode: "bodies", items: [ stale ])
    assert status.success?, err
    assert_equal({ "x" => { "body_status" => "unavailable" } }, JSON.parse(out))
    refute_includes out, "private"
  end

  test "a declared journal that is missing or linked leaves the tab unavailable, not empty" do
    @home.join("real").mkpath
    File.symlink(@home.join("real"), @home.join("linked"))
    [ { "path" => "missing" }, { "path" => "linked" }, { "path" => "../real" } ].each do |journal|
      declare(journal)
      _out, _err, status = execute(mode: "overview")
      refute status.success?, journal.inspect
    end
  end

  test "an admin's chosen file is the journal only when the home declares nothing" do
    write("growth.md", "## one\n## two\n")
    write("daily-journals/2026-11-20.md", "## daily\n")
    assert_equal 2, run_reader(mode: "overview", journal_source: "memory/growth.md")["count"]
    declare({ "path" => "memory/daily-journals" })
    assert_equal 1, run_reader(mode: "overview", journal_source: "memory/growth.md")["count"]
  end

  # Mira, #1113: a cached overview or catalog must not outlive "journal": false.
  test "the current declaration gates a cached overview and catalog" do
    write("daily-journals/2026-11-20.md", "## 09:00 private title\nbody\n")
    agent = agents(:research_assistant)
    agent.update_columns(runtime: "external", container_name: "test-resident", sandbox_host: nil)
    archive = Agents::MemoryArchive.new(agent)
    calls = Hash.new(0)
    local = lambda do |_script, request|
      calls[JSON.parse(request)["mode"]] += 1
      out, err, status = execute(JSON.parse(request))
      assert status.success?, err
      out
    end
    Rails.stub(:cache, ActiveSupport::Cache::MemoryStore.new) do
      Agents::Resources.stub(:new, Struct.new(:verify_existing!).new(true)) do
        archive.stub(:capture, local) do
          assert_equal 1, archive.overview["count"]
          assert_equal "09:00 private title", archive.catalog["items"].first["title"]
          archive.overview
          assert_equal 1, calls["overview"], "the overview is cached"
          declare(false)
          closed = archive.overview
          assert_equal "not_shared", closed["status"]
          assert_nil closed["count"]
          assert_equal [], archive.catalog["items"]
          refute_includes Agents::MemoryHistory.new(agent, archive: archive).call(kinds: %w[journals]).to_json, "private title"
          declare({ "path" => "memory/daily-journals" })
          assert_equal 1, archive.overview["count"]
        end
      end
    end
  end

  test "unavailable residents never masquerade as empty archives" do
    agent = agents(:research_assistant)
    agent.container_name = nil
    result = Agents::MemoryArchive.new(agent).overview
    assert_equal "unavailable", result["status"]
    assert_nil result["count"]
  end

  private

  def write(path, body) = @root.join(path).write(body)

  def declare(journal)
    @home.join("resident-home.json").write({ "format" => "souls-home/v1", "journal" => journal }.to_json)
  end

  def execute(request)
    script = Agents::MemoryArchive::SCRIPT.sub('HOME = "/home/agent/identity"', "HOME = #{@home.to_s.to_json}")
    Open3.capture3("python3", "-c", script, stdin_data: request.to_json)
  end

  def run_reader(request)
    out, err, status = execute(request)
    assert status.success?, err
    JSON.parse(out)
  end

end
