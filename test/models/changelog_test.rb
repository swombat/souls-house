require "test_helper"

class ChangelogTest < ActiveSupport::TestCase

  test "entries are complete and newest first" do
    entries = Changelog.entries
    assert entries.any?
    entries.each { |entry| assert entry.values_at(:date, :title, :body).all?(&:present?), entry.inspect }
    dates = entries.map { |entry| entry[:date] }
    assert_equal dates.sort.reverse, dates
  end

  test "recent keeps the last fourteen days and drops older entries" do
    newest = Date.iso8601(Changelog.entries.first[:date])
    assert_equal Changelog.entries.size, Changelog.recent(today: Date.iso8601(Changelog.entries.last[:date])).size
    later = Changelog.recent(today: newest + 14)
    assert_empty later
    assert_includes Changelog.recent(today: newest + 13).map { |e| e[:date] }, newest.iso8601
  end

end
