# The link preview a public page gives crawlers (X, LinkedIn, WhatsApp, Slack),
# which read the server's HTML and never run the page's JavaScript. The words
# live in config/link_previews.json, which the Svelte pages import too.
class LinkPreview

  SOURCE = Rails.root.join("config/link_previews.json")
  IMAGE_PATH = "/hero/film.jpg"
  IMAGE_WIDTH = 1280
  IMAGE_HEIGHT = 720

  attr_reader :key, :title, :description

  def self.entries
    @entries ||= JSON.parse(SOURCE.read).except("_comment").freeze
  end

  def self.for(key)
    entry = entries.fetch(key.to_s)
    new(key: key.to_s, title: entry.fetch("title"), description: entry.fetch("description"))
  end

  def initialize(key:, title:, description:)
    @key = key
    @title = title
    @description = description
  end

  def page_title(site_name)
    "#{title} — #{site_name}"
  end

end
