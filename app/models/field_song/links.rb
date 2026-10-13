# Where a song can be heard. Each link is kept as { provider, url, embed_id }:
# the provider read from the address, and for Spotify and YouTube the id the
# page builds its player from. The address itself is kept as given (cleaned),
# so "Open on Spotify" always works even when an embed doesn't.
module FieldSong::Links

  MAX_URL = 500
  PROVIDERS = %w[spotify youtube apple_music bandcamp soundcloud other].freeze
  LABELS = { "spotify" => "Spotify", "youtube" => "YouTube", "apple_music" => "Apple Music",
             "bandcamp" => "Bandcamp", "soundcloud" => "SoundCloud", "other" => "the web" }.freeze

  SPOTIFY = %r{\Ahttps://open\.spotify\.com/(?:intl-[a-z]{2}(?:-[A-Za-z]{2})?/)?(track|album|playlist|episode)/([A-Za-z0-9]{10,40})(?:[/?#]|\z)}
  YOUTUBE_ID = /\A[A-Za-z0-9_-]{11}\z/

  module_function

  def web_url?(value)
    value = value.to_s.strip
    return false if value.empty? || value.length > MAX_URL || value.match?(/\s/)

    uri = URI.parse(value)
    %w[http https].include?(uri.scheme) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  # [{ "provider", "url", "embed_id" }] from strings or hashes, duplicates
  # (same address) dropped, order kept.
  def normalise_list(list)
    Array(list).filter_map { |item| normalise(item.is_a?(Hash) ? (item["url"] || item[:url]) : item) }
      .uniq { |link| link["url"] }
  end

  def normalise(value)
    url = value.to_s.strip
    return nil unless web_url?(url)

    uri = URI.parse(url)
    uri.scheme = "https" if uri.scheme == "http"
    host = uri.host.downcase.delete_prefix("www.").delete_prefix("m.")
    url = uri.to_s

    provider, embed_id = identify(host, uri, url)
    { "provider" => provider, "url" => url, "embed_id" => embed_id }
  end

  def identify(host, uri, url)
    case host
    when "open.spotify.com"
      match = url.match(SPOTIFY)
      [ "spotify", (match && "#{match[1]}/#{match[2]}") ]
    when "youtube.com", "music.youtube.com", "youtube-nocookie.com"
      [ "youtube", youtube_id(uri) ]
    when "youtu.be"
      id = uri.path.to_s.delete_prefix("/").split("/").first.to_s
      [ "youtube", (id if id.match?(YOUTUBE_ID)) ]
    when "music.apple.com" then [ "apple_music", nil ]
    when "soundcloud.com", "on.soundcloud.com" then [ "soundcloud", nil ]
    else
      host.end_with?(".bandcamp.com") || host == "bandcamp.com" ? [ "bandcamp", nil ] : [ "other", nil ]
    end
  end

  def youtube_id(uri)
    path = uri.path.to_s
    id = if path == "/watch"
      URI.decode_www_form(uri.query.to_s).to_h["v"]
    elsif (match = path.match(%r{\A/(?:shorts|embed|live|v)/([^/?#]+)}))
      match[1]
    end
    id if id.to_s.match?(YOUTUBE_ID)
  rescue ArgumentError
    nil
  end

  def label(provider) = LABELS.fetch(provider.to_s, LABELS["other"])

end
