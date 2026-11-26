require "builder"

class Changelog
  # Atom 1.0 (RFC 4287) feed for the public changelog at /changelog.atom.
  # Each entry links to its own /changelog/<slug> page so feed readers (Feedbin,
  # NetNewsWire, Readwise, Slack /feed) can subscribe and open individual changes.
  class AtomFeed

    XMLNS = "http://www.w3.org/2005/Atom"

    def self.render(entries:, base_url:, site_name:, subtitle:)
      new(entries:, base_url:, site_name:, subtitle:).render
    end

    def initialize(entries:, base_url:, site_name:, subtitle:)
      @entries = entries
      @base_url = base_url.to_s.chomp("/")
      @site_name = site_name
      @subtitle = subtitle
    end

    def render
      xml = Builder::XmlMarkup.new(indent: 2)
      xml.instruct! :xml, version: "1.0", encoding: "UTF-8"
      xml.feed(xmlns: XMLNS, "xml:lang" => "en") do |feed|
        feed.id "#{@base_url}/changelog.atom"
        feed.title "Changelog — #{@site_name}"
        feed.subtitle @subtitle
        feed.link rel: "self", type: "application/atom+xml", href: "#{@base_url}/changelog.atom"
        feed.link rel: "alternate", type: "text/html", href: "#{@base_url}/changelog"
        feed.updated feed_updated_at
        feed.icon "#{@base_url}/favicon.ico"
        feed.author do |author|
          author.name @site_name
          author.uri @base_url
        end

        @entries.each { |entry| build_entry(feed, entry) }
      end
    end

    private

    def feed_updated_at
      @entries.first&.dig(:published_at) || Time.current.utc.iso8601
    end

    def build_entry(feed, entry)
      entry_url = "#{@base_url}/changelog/#{entry[:slug]}"
      timestamp = entry[:published_at] || "#{entry[:date]}T00:00:00Z"

      feed.entry do |item|
        item.id entry_url
        item.title entry[:title]
        item.link rel: "alternate", type: "text/html", href: entry_url
        item.published timestamp
        item.updated timestamp
        item.content entry_html(entry, entry_url), type: "html"

        if (clip = entry[:clip])
          enclosure = { rel: "enclosure", type: "video/mp4", href: "#{@base_url}#{clip[:src]}" }
          clip_file = Rails.root.join("public#{clip[:src]}")
          enclosure[:length] = clip_file.size if clip_file.file?
          item.link enclosure
        end
      end
    end

    def entry_html(entry, entry_url)
      escaped_body = ERB::Util.html_escape(entry[:body])
      parts = [ "<p>#{escaped_body}</p>" ]

      if (clip = entry[:clip])
        poster_url = ERB::Util.html_escape("#{@base_url}#{clip[:poster]}")
        escaped_url = ERB::Util.html_escape(entry_url)
        escaped_title = ERB::Util.html_escape(entry[:title])
        parts << "<p><a href=\"#{escaped_url}\"><img src=\"#{poster_url}\" alt=\"#{escaped_title}\" width=\"#{LinkPreview::IMAGE_WIDTH}\" height=\"#{LinkPreview::IMAGE_HEIGHT}\" /></a></p>"
      end

      parts.join("\n")
    end

  end
end
