# The public changelog, read from config/changelog/*.yml (newest first by filename).
# Each file is named YYYY-MM-DD-HHMM-slug.yml and holds one entry (date, title, body,
# and optionally clip). An entry may name a clip: `clip: cli` plays
# public/changelog-clips/cli.mp4 with cli.jpg as its poster.
# Each entry has its own public page at /changelog/<slug>, where the slug is the
# filename without its date, time and extension; slugs are unique across the changelog.
class Changelog

  DIR = Rails.root.join("config/changelog")
  SLUG = /[a-z0-9]+(?:-[a-z0-9]+)*/
  FILENAME = /\A(?<date>\d{4}-\d{2}-\d{2})-(?<time>\d{4})-(?<slug>#{SLUG})\.yml\z/
  CLIP_DIR = "changelog-clips"
  RECENT_DAYS = 14

  def self.entries(dir: DIR)
    entry_files(dir:).map { |path| parse_entry(path) }
  end

  def self.entry_files(dir: DIR)
    Dir.glob(Pathname(dir).join("*.yml")).sort.reverse
  end

  def self.slug_for(path)
    FILENAME.match(File.basename(path))&.[](:slug)
  end

  # One entry by its slug, with the slug, title and date of the entries either
  # side (newer and older), or nil when no entry has that slug.
  def self.find(slug, dir: DIR)
    files = entry_files(dir:)
    index = files.index { |path| slug_for(path) == slug.to_s }
    return unless index

    neighbour = ->(path) { path && parse_entry(path).slice(:slug, :title, :date) }
    newer = index.positive? ? files[index - 1] : nil
    parse_entry(files[index]).merge(newer: neighbour.(newer), older: neighbour.(files[index + 1]))
  end

  def self.parse_entry(path)
    entry = YAML.safe_load_file(path, permitted_classes: [ Date ])
    row = { slug: slug_for(path), date: entry.fetch("date").to_date.iso8601, title: entry.fetch("title"), body: entry.fetch("body") }
    if (clip = entry["clip"])
      row[:clip] = { name: clip, src: "/#{CLIP_DIR}/#{clip}.mp4", poster: "/#{CLIP_DIR}/#{clip}.jpg" }
    end
    row
  end

  def self.recent(today: Date.current, dir: DIR)
    cutoff = today - RECENT_DAYS
    result = []
    entry_files(dir:).each do |path|
      match = FILENAME.match(File.basename(path))
      break if match && Date.iso8601(match[:date]) <= cutoff

      entry = parse_entry(path)
      result << entry if Date.iso8601(entry[:date]) > cutoff
    end
    result
  end

  # The newest entries that carry a clip, for the home page: those are the changes worth showing.
  def self.clipped(limit, dir: DIR)
    return [] if limit <= 0

    result = []
    entry_files(dir:).each do |path|
      entry = parse_entry(path)
      next unless entry[:clip]

      result << entry
      break if result.size >= limit
    end
    result
  end

end
