# The link preview a public page gives crawlers (X, LinkedIn, WhatsApp, Slack),
# which read the server's HTML and never run the page's JavaScript. The words
# live in config/link_previews.json, which the Svelte pages import too.
class LinkPreview

  SOURCE = Rails.root.join("config/link_previews.json")
  IMAGE_PATH = "/hero/film.jpg"
  IMAGE_WIDTH = 1280
  IMAGE_HEIGHT = 720
  DESCRIPTION_LENGTH = 200

  attr_reader :key, :title, :description, :image_path, :video_path

  def self.entries
    @entries ||= JSON.parse(SOURCE.read).except("_comment").freeze
  end

  def self.for(key)
    entry = entries.fetch(key.to_s)
    new(key: key.to_s, title: entry.fetch("title"), description: entry.fetch("description"))
  end

  # One changelog entry's own page: its title, the start of its body, and its
  # clip's poster (every poster is 1280x720, like the hero still) with the clip
  # itself as og:video. No X player card: X wants an https page to frame, not an mp4.
  def self.for_changelog_entry(entry)
    clip = entry[:clip]
    new(key: "changelog_entry", title: entry[:title],
        description: entry[:body].squish.truncate(DESCRIPTION_LENGTH, separator: " "),
        image_path: clip&.dig(:poster) || IMAGE_PATH, video_path: clip&.dig(:src))
  end

  def self.for_decision(decision)
    new(key: "decision", title: decision[:title],
        description: decision[:summary].squish.truncate(DESCRIPTION_LENGTH, separator: " "))
  end

  def self.for_data_model_area(area)
    section = entries.fetch("data_model").fetch("title")
    new(key: "data_model_area", title: "#{area.title} — #{section}",
        description: area.summary.squish.truncate(DESCRIPTION_LENGTH, separator: " "))
  end

  def self.for_tool_shed_entry(tool)
    section = entries.fetch("tool_shed").fetch("title")
    new(key: "tool_shed_entry", title: "#{tool[:name]} — #{section}",
        description: tool[:summary].squish.truncate(DESCRIPTION_LENGTH, separator: " "))
  end

  def initialize(key:, title:, description:, image_path: IMAGE_PATH, video_path: nil)
    @key = key
    @title = title
    @description = description
    @image_path = image_path
    @video_path = video_path
  end

  def page_title(site_name)
    "#{title} — #{site_name}"
  end

end
