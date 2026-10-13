require "net/http"
require "json"

# Suggestions for a song being added to the Field: a title and artist from a
# link (YouTube's and Spotify's public oEmbed), and candidate lyrics from
# LRCLIB (lrclib.net, free, no key). Suggestions only: nothing here saves a
# song, and the person (or resident) checks a candidate before using it.
#
# Bounded on purpose. Requests go only to the fixed endpoints below, built
# from parsed ids, never to an address someone submitted; redirects aren't
# followed; each answer is cut off at MAX_BYTES and TIMEOUT. What comes back
# (titles, lyrics) is untrusted text: scrubbed and cut to length.
class FieldSongLookup

  TIMEOUT = 6
  MAX_BYTES = 768.kilobytes
  MAX_CANDIDATES = 5
  # Says which house is asking, from config/house.env (never a hardcoded name).
  USER_AGENT = [ "Field songs lookup", ENV["HOUSE_DOMAIN"].presence&.then { |d| "(https://#{d})" } ].compact.join(" ")
  YOUTUBE_OEMBED = "https://www.youtube.com/oembed"
  SPOTIFY_OEMBED = "https://open.spotify.com/oembed"
  LRCLIB_SEARCH = "https://lrclib.net/api/search"
  # Words YouTube uploaders hang off a title that aren't part of the song's name.
  TITLE_NOISE = /\s*[(\[][^)\]]*\b(official|video|audio|lyrics?|visuali[sz]er|hd|hq|4k|remaster(ed)?|mv|clip officiel)\b[^)\]]*[)\]]/i

  # The provider couldn't be reached or answered with something unreadable.
  class Failed < StandardError; end
  # The question can't be asked: no title, or not a web address.
  class Unusable < StandardError; end

  Candidate = Data.define(:id, :title, :artist, :album, :duration_s, :instrumental, :lyrics) do
    def as_json(*) = to_h
  end

  # mattr-style seam so tests can stub the network at one point if needed.
  def initialize(timeout: TIMEOUT, max_bytes: MAX_BYTES)
    @timeout = timeout
    @max_bytes = max_bytes
  end

  # { link: { provider, url, embed_id }, title:, artist:, found: true/false,
  #   message: } from a pasted link. Raises Failed when the address isn't a
  # web link.
  def from_link(url)
    link = FieldSong::Links.normalise(url)
    raise Unusable, "That isn't a web address" unless link

    suggestion = case link["provider"]
    when "youtube" then youtube(link)
    when "spotify" then spotify(link)
    end
    base = { link: link, title: nil, artist: nil, found: false,
             message: "No title from #{FieldSong::Links.label(link["provider"])}; type it in." }
    suggestion ? base.merge(suggestion) : base
  end

  # Up to MAX_CANDIDATES lyric candidates for a title and artist, the closest
  # first: ones with words before ones without, then (given a duration) the
  # nearest in length. [] when LRCLIB knows no match. Raises Failed when
  # LRCLIB can't be reached or answers with something unreadable.
  def lyrics(title:, artist: nil, duration_ms: nil)
    title = title.to_s.squish.first(200)
    raise Unusable, "A title is needed to look for lyrics" if title.empty?

    query = { track_name: title }
    query[:artist_name] = artist.to_s.squish.first(200) if artist.present?
    data = get_json(LRCLIB_SEARCH, query)
    raise Failed, "LRCLIB answered with something unexpected" unless data.is_a?(Array)

    candidates = data.first(50).filter_map { |row| candidate_from(row) }
    seconds = duration_ms.to_i.positive? ? duration_ms.to_i / 1000.0 : nil
    candidates.sort_by.with_index do |candidate, index|
      [ (candidate.lyrics.present? || candidate.instrumental) ? 0 : 1,
        seconds && candidate.duration_s ? (candidate.duration_s - seconds).abs : 0, index ]
    end.first(MAX_CANDIDATES)
  end

  # "Artist - Song (Official Video)" => ["Artist", "Song"]; [nil, title]
  # when there is no dash to split on.
  def self.split_title(raw)
    title = raw.to_s.gsub(TITLE_NOISE, "").squish
    parts = title.split(/\s+[-–—]\s+/, 2)
    parts.size == 2 && parts.all?(&:present?) ? [ parts[0], parts[1] ] : [ nil, title.presence ]
  end

  private

  def youtube(link)
    return nil unless link["embed_id"]

    data = get_json(YOUTUBE_OEMBED, { url: "https://www.youtube.com/watch?v=#{link["embed_id"]}", format: "json" }, missing_ok: true)
    return { message: "YouTube didn't find that video. It may be private or removed; type the title in." } unless data.is_a?(Hash)

    artist, title = self.class.split_title(clean(data["title"]))
    channel = clean(data["author_name"]).to_s.sub(/\s*-\s*Topic\z/i, "").sub(/VEVO\z/, "").presence
    { title: title, artist: artist || channel, found: title.present?, message: nil }
  end

  def spotify(link)
    return nil unless link["embed_id"]

    data = get_json(SPOTIFY_OEMBED, { url: "https://open.spotify.com/#{link["embed_id"]}" }, missing_ok: true)
    return { message: "Spotify didn't find that link; type the title in." } unless data.is_a?(Hash)

    title = clean(data["title"])
    { title: title, found: title.present?, message: ("Spotify gives the title only; add the artist." if title) }
  end

  def candidate_from(row)
    return nil unless row.is_a?(Hash) && row["id"].is_a?(Integer)

    lyrics = row["plainLyrics"].to_s.scrub("").delete("\u0000").gsub("\r\n", "\n").strip.first(FieldSong::MAX_LYRICS).presence
    Candidate.new(
      id: row["id"], title: clean(row["trackName"]), artist: clean(row["artistName"]), album: clean(row["albumName"]),
      duration_s: (row["duration"].round if row["duration"].is_a?(Numeric)),
      instrumental: row["instrumental"] == true, lyrics: lyrics
    )
  end

  def clean(value) = value.is_a?(String) ? value.scrub("").delete("\u0000").squish.first(200).presence : nil

  # GET one of the fixed endpoints. nil for a 404/400/401/403 when
  # missing_ok (oEmbed's "no such video"). Raises Failed otherwise.
  def get_json(base, query, missing_ok: false)
    uri = URI(base)
    uri.query = URI.encode_www_form(query)
    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "application/json"
    request["User-Agent"] = USER_AGENT

    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = true
    http.open_timeout = @timeout
    http.read_timeout = @timeout
    http.write_timeout = @timeout
    http.max_retries = 0

    status = nil
    body = +""
    Timeout.timeout(@timeout * 2) do
      http.start do |connection|
        connection.request(request) do |response|
          status = response.code.to_i
          # Every answer is read through the cap, errors and redirects too:
          # a body left unread here gets buffered whole by Net::HTTP after
          # the block returns, outside any limit.
          response.read_body do |chunk|
            body << chunk
            raise Failed, "#{uri.host} answered with more than we read" if body.bytesize > @max_bytes
          end
        end
      end
    end

    return nil if missing_ok && [ 400, 401, 403, 404 ].include?(status)
    raise Failed, "#{uri.host} answered #{status}" unless status && (200..299).cover?(status)

    JSON.parse(body)
  rescue JSON::ParserError
    raise Failed, "#{uri.host} answered with something that isn't JSON"
  rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError, Net::HTTPBadResponse
    raise Failed, "Couldn't reach #{uri.host}"
  end

end
