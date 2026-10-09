# The public changelog, read from config/changelog.yml (newest first).
# An entry may name a clip: `clip: cli` plays public/changelog-clips/cli.mp4 with cli.jpg as its poster.
class Changelog

  PATH = Rails.root.join("config/changelog.yml")
  CLIP_DIR = "changelog-clips"
  RECENT_DAYS = 14

  def self.entries
    YAML.safe_load_file(PATH, permitted_classes: [ Date ]).map do |entry|
      row = { date: entry.fetch("date").to_date.iso8601, title: entry.fetch("title"), body: entry.fetch("body") }
      if (clip = entry["clip"])
        row[:clip] = { name: clip, src: "/#{CLIP_DIR}/#{clip}.mp4", poster: "/#{CLIP_DIR}/#{clip}.jpg" }
      end
      row
    end
  end

  def self.recent(today: Date.current)
    cutoff = today - RECENT_DAYS
    entries.select { |entry| Date.iso8601(entry[:date]) > cutoff }
  end

end
