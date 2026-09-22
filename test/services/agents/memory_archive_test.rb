require "test_helper"
require "tmpdir"
require "open3"

class Agents::MemoryArchiveTest < ActiveSupport::TestCase
  setup do
    @root = Pathname.new(Dir.mktmpdir).realpath
    %w[daily weekly monthly yearly].each { |layer| @root.join("#{layer}-journals").mkpath }
  end

  teardown { FileUtils.remove_entry(@root) }

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
    assert_equal "partial", result["status"]
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
    assert_equal 1, catalog["count"]
    body = run_reader(mode: "bodies", items: catalog["items"]).values.first
    assert_equal "truncated", body["body_status"]
    assert_equal 65_536, body["body"].bytesize
  end

  test "refuses symlink ancestors and client path traversal" do
    FileUtils.remove_entry(@root.join("weekly-journals"))
    File.symlink(@root.join("daily-journals"), @root.join("weekly-journals"))
    _out, _err, status = execute(mode: "catalog")
    refute status.success?
    _out, _err, status = execute(mode: "bodies", items: [ { path: "daily-journals/../../secret" } ])
    refute status.success?
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

  def execute(request)
    script = Rails.root.join("app/services/agents/memory_archive.py").read.sub('"/home/agent/identity/memory"', @root.to_s.to_json)
    Open3.capture3("python3", "-c", script, stdin_data: request.to_json)
  end

  def run_reader(request)
    out, err, status = execute(request)
    assert status.success?, err
    JSON.parse(out)
  end
end
