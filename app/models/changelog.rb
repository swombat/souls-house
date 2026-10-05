# The public changelog, read from config/changelog.yml (newest first).
class Changelog

  PATH = Rails.root.join("config/changelog.yml")
  RECENT_DAYS = 14

  def self.entries
    YAML.safe_load_file(PATH, permitted_classes: [ Date ]).map do |entry|
      { date: entry.fetch("date").to_date.iso8601, title: entry.fetch("title"), body: entry.fetch("body") }
    end
  end

  def self.recent(today: Date.current)
    cutoff = today - RECENT_DAYS
    entries.select { |entry| Date.iso8601(entry[:date]) > cutoff }
  end

end
