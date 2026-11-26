require "test_helper"

class ChangelogTest < ActiveSupport::TestCase

  test "the legacy single-file config/changelog.yml does not exist" do
    refute Rails.root.join("config/changelog.yml").exist?,
      "config/changelog.yml was replaced by config/changelog/*.yml; move any new entries into config/changelog/"
  end

  test "entries are complete and newest first" do
    entries = Changelog.entries
    assert entries.any?
    entries.each { |entry| assert entry.values_at(:date, :title, :body).all?(&:present?), entry.inspect }
    dates = entries.map { |entry| entry[:date] }
    assert_equal dates.sort.reverse, dates
  end

  test "every changelog filename matches YYYY-MM-DD-HHMM-slug.yml and agrees with its date" do
    files = Changelog.entry_files
    assert files.any?
    files.each do |path|
      name = File.basename(path)
      match = Changelog::FILENAME.match(name)
      assert match, "Invalid changelog filename: #{name} (expected YYYY-MM-DD-HHMM-slug.yml)"
      hour = match[:time][0, 2].to_i
      minute = match[:time][2, 2].to_i
      assert_includes 0..23, hour, "Invalid hour in changelog filename: #{name}"
      assert_includes 0..59, minute, "Invalid minute in changelog filename: #{name}"
      assert_equal match[:date], Changelog.parse_entry(path)[:date], "Filename date disagrees with entry date: #{name}"
    end
  end

  test "entries sort newest first by filename, including within the same day" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "2026-11-25-0900-first.yml"), "date: 2026-11-25\ntitle: First\nbody: Morning change.\n")
      File.write(File.join(dir, "2026-11-25-1430-second.yml"), "date: 2026-11-25\ntitle: Second\nbody: Afternoon change.\n")
      File.write(File.join(dir, "2026-11-24-2359-earlier.yml"), "date: 2026-11-24\ntitle: Earlier\nbody: Yesterday.\n")

      assert_equal %w[Second First Earlier], Changelog.entries(dir:).map { |entry| entry[:title] }
    end
  end

  test "every clip an entry names exists, with its poster" do
    clips = Changelog.entries.filter_map { |entry| entry[:clip] }
    assert clips.any?
    clips.each do |clip|
      assert_match(/\A[a-z0-9-]+\z/, clip[:name])
      [ clip[:src], clip[:poster] ].each { |path| assert Rails.root.join("public#{path}").file?, "missing #{path}" }
    end
  end

  test "recent keeps the last fourteen days and drops older entries" do
    newest = Date.iso8601(Changelog.entries.first[:date])
    assert_equal Changelog.entries.size, Changelog.recent(today: Date.iso8601(Changelog.entries.last[:date])).size
    later = Changelog.recent(today: newest + 14)
    assert_empty later
    assert_includes Changelog.recent(today: newest + 13).map { |e| e[:date] }, newest.iso8601
  end

  test "clipped and recent stop reading older files once satisfied" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "2026-11-25-1200-newest-clip.yml"), "date: 2026-11-25\ntitle: Newest\nbody: Newest.\nclip: one\n")
      File.write(File.join(dir, "2026-11-25-1100-no-clip.yml"), "date: 2026-11-25\ntitle: Plain\nbody: No clip.\n")
      File.write(File.join(dir, "2026-11-24-1000-second-clip.yml"), "date: 2026-11-24\ntitle: Second\nbody: Second.\nclip: two\n")
      # Older unreadable/invalid YAML would raise if scanned past the stop condition.
      File.write(File.join(dir, "2026-10-01-0001-unreached.yml"), ": [unclosed\n")

      assert_equal %w[Newest Second], Changelog.clipped(2, dir:).map { |entry| entry[:title] }
      assert_equal [], Changelog.clipped(0, dir:)
      assert_equal %w[Newest Plain Second], Changelog.recent(today: Date.iso8601("2026-11-25"), dir:).map { |entry| entry[:title] }
    end
  end

  test "clipped keeps only entries with a clip, newest first, up to the limit" do
    with_clip = Changelog.entries.select { |entry| entry[:clip] }
    assert_equal with_clip.first(3), Changelog.clipped(3)
    assert_equal with_clip, Changelog.clipped(with_clip.size + 5)
  end

  # Each entry's page is /changelog/<slug>; a second file with the same slug would
  # silently shadow the first, so the slugs must stay unique across the whole changelog.
  test "every entry's slug is unique" do
    slugs = Changelog.entry_files.map { |path| Changelog.slug_for(path) }
    assert slugs.all?(&:present?)
    duplicates = slugs.tally.select { |_, count| count > 1 }.keys
    assert_empty duplicates, "Changelog slugs must be unique (the page is /changelog/<slug>); rename: #{duplicates.join(', ')}"
  end

  test "entries carry their slug, the filename without date, time and extension" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "2026-11-25-0900-a-new-thing.yml"), "date: 2026-11-25\ntitle: A\nbody: B.\n")

      assert_equal "a-new-thing", Changelog.entries(dir:).first[:slug]
    end
  end

  test "find returns one entry with the entries either side, and nil for an unknown slug" do
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "2026-11-25-1200-newest.yml"), "date: 2026-11-25\ntitle: Newest\nbody: N.\n")
      File.write(File.join(dir, "2026-11-25-1100-middle.yml"), "date: 2026-11-25\ntitle: Middle\nbody: M.\nclip: one\n")
      File.write(File.join(dir, "2026-11-24-1000-oldest.yml"), "date: 2026-11-24\ntitle: Oldest\nbody: O.\n")

      middle = Changelog.find("middle", dir:)
      assert_equal "Middle", middle[:title]
      assert_equal "/changelog-clips/one.jpg", middle[:clip][:poster]
      assert_equal({ slug: "newest", title: "Newest", date: "2026-11-25" }, middle[:newer])
      assert_equal({ slug: "oldest", title: "Oldest", date: "2026-11-24" }, middle[:older])

      assert_nil Changelog.find("newest", dir:)[:newer]
      assert_nil Changelog.find("oldest", dir:)[:older]
      assert_nil Changelog.find("missing", dir:)
    end
  end

end
