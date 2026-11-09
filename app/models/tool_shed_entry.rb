# A tool its builder has offered to other houses, read from app/content/tool-shed/<slug>/entry.md
# (front matter plus a body saying how to install and use it). The catalogue is
# plain files in the repository, so a self-hosted house carries the same shed with
# no central service. See app/content/tool-shed/README.md for how to offer a tool.
class ToolShedEntry

  DIR = Rails.root.join("app/content/tool-shed")
  AVAILABILITIES = %w[included separate].freeze
  REQUIRED = %w[slug name credit summary source_url version licence availability offered].freeze

  class Invalid < StandardError; end

  def self.all(dir: DIR)
    dir.glob("*/entry.md").map { |path| from_file(path) }.sort_by { |entry| entry[:name].downcase }
  end

  def self.find(slug, dir: DIR)
    all(dir: dir).find { |entry| entry[:slug] == slug } or raise ActiveRecord::RecordNotFound
  end

  def self.from_file(path)
    _, front_matter, body = path.read.split(/^---\s*$/, 3)
    meta = YAML.safe_load(front_matter.to_s, permitted_classes: [ Date ]) || {}

    missing = REQUIRED.reject { |key| meta[key].present? }
    raise Invalid, "#{path}: missing #{missing.join(', ')}" if missing.any?
    raise Invalid, "#{path}: slug must match its directory" unless meta["slug"] == path.dirname.basename.to_s
    unless AVAILABILITIES.include?(meta["availability"])
      raise Invalid, "#{path}: availability must be one of #{AVAILABILITIES.join(', ')}"
    end

    raise Invalid, "#{path}: the body must say how to install and use the tool" if body.to_s.strip.empty?

    tested_in = Array(meta["tested_in"]).map(&:to_s).compact_blank
    raise Invalid, "#{path}: tested_in must name at least one place it has actually run" if tested_in.empty?

    {
      slug: meta["slug"],
      name: meta["name"],
      credit: meta["credit"],
      summary: meta["summary"],
      source_url: meta["source_url"],
      version: meta["version"].to_s,
      licence: meta["licence"],
      availability: meta["availability"],
      requires: Array(meta["requires"]).map(&:to_s).compact_blank,
      tested_in: tested_in,
      offered: meta["offered"],
      body_html: render(body.to_s)
    }
  end

  def self.render(markdown)
    Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(filter_html: true, safe_links_only: true),
      autolink: true, no_intra_emphasis: true, tables: true, fenced_code_blocks: true).render(markdown.strip)
  end

end
