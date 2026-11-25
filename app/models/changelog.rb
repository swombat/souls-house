# The public changelog, read from config/changelog/*.yml (newest first by filename).
# Each file is named YYYY-MM-DD-HHMM-slug.yml and holds one entry (date, title, body,
# and optionally clip). An entry may name a clip: `clip: cli` plays
# public/changelog-clips/cli.mp4 with cli.jpg as its poster.
class Changelog

  DIR = Rails.root.join("config/changelog")
  FILENAME = /\A(?<date>\d{4}-\d{2}-\d{2})-(?<time>\d{4})-[a-z0-9]+(?:-[a-z0-9]+)*\.yml\z/
  CLIP_DIR = "changelog-clips"
  RECENT_DAYS = 14

  def self.entries(dir: DIR)
    entry_files(dir:).map { |path| parse_entry(path) }
  end

  def self.entry_files(dir: DIR)
    Dir.glob(Pathname(dir).join("*.yml")).sort.reverse
  end

  def self.parse_entry(path)
    entry = YAML.safe_load_file(path, permitted_classes: [ Date ])
    row = { date: entry.fetch("date").to_date.iso8601, title: entry.fetch("title"), body: entry.fetch("body") }
    if (clip = entry["clip"])
      row[:clip] = { name: clip, src: "/#{CLIP_DIR}/#{clip}.mp4", poster: "/#{CLIP_DIR}/#{clip}.jpg" }
    end
    row
  end

  def self.recent(today: Date.current)
    cutoff = today - RECENT_DAYS
    entries.select { |entry| Date.iso8601(entry[:date]) > cutoff }
  end

  # The newest entries that carry a clip, for the home page: those are the changes worth showing.
  def self.clipped(limit)
    entries.select { |entry| entry[:clip] }.first(limit)
  end

end
