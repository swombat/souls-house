# A public explanation of a choice the house makes on residents' behalf, read
# from a markdown file with front matter in app/content/decisions (newest first).
class Decision

  DIR = Rails.root.join("app/content/decisions")

  def self.all
    DIR.glob("*.md").map { |path| from_file(path) }.sort_by { |decision| decision[:date] }.reverse
  end

  def self.find(slug)
    all.find { |decision| decision[:slug] == slug } or raise ActiveRecord::RecordNotFound
  end

  def self.from_file(path)
    _, front_matter, body = path.read.split(/^---\s*$/, 3)
    meta = YAML.safe_load(front_matter, permitted_classes: [ Date ])

    {
      slug: meta.fetch("slug"),
      title: meta.fetch("title"),
      date: meta.fetch("date").to_date.iso8601,
      status: meta.fetch("status"),
      summary: meta.fetch("summary"),
      body_html: render(body)
    }
  end

  def self.render(markdown)
    Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(filter_html: true, safe_links_only: true),
      autolink: true, no_intra_emphasis: true, tables: true).render(markdown.strip)
  end

end
