# An outside link can be offered without looking anything up or copying the
# conversation into the Field. Stricter than ordinary Field links on purpose.
class FieldSong::Offer

  class InvalidLink < StandardError; end

  attr_reader :link

  def initialize(account:, url:)
    @account = account
    @url = url.to_s.strip
    @link = FieldSong::Links.normalise(url)
    uri = URI.parse(url.to_s.strip) if @link
    unless @link && @link["provider"] != "other" && uri.userinfo.nil? &&
        uri.port == uri.default_port
      raise InvalidLink, "Use a Spotify, YouTube, Apple Music, Bandcamp or SoundCloud web link."
    end
  rescue URI::InvalidURIError, URI::InvalidComponentError
    raise InvalidLink, "Use a Spotify, YouTube, Apple Music, Bandcamp or SoundCloud web link."
  end

  def existing_song
    @account.field_songs.kept.find_each do |song|
      return song if song.links.any? { |saved| identity(FieldSong::Links.normalise(saved["url"])) == identity(link) }
    end
    nil
  end

  # The resident whose message offered this link, or nil. The message must be
  # a resident's reply in a conversation of this account, written by one of
  # its own residents, and must carry an offer of exactly this link: the page
  # names the message, the server decides whether it counts.
  def suggester(message_id)
    return if message_id.blank?

    message = Message.find_by_obfuscated_id(message_id.to_s) rescue nil
    return unless message&.role == "assistant" && message.chat&.account_id == @account.id

    agent = message.agent
    return unless agent && agent.account_id == @account.id
    return unless FieldSong::Offer.offered_urls(message.content).include?(@url)

    agent
  end

  # An existing song keeps its attribution: whoever offers the same link
  # later finds the song, they don't take it over.
  def save!(title:, artist:, by:, suggested_by: nil)
    song = @account.field_songs.new(title: title, artist: artist, links: [ link ], added_by: by,
      suggested_by: suggested_by)
    song.validate!

    # A transaction alone permits two requests to both observe no match.
    # Every offer writer takes this same account row lock before looking.
    @account.with_lock do
      existing_song || song.tap(&:save!)
    end
  end

  # The URLs of the [[song:URL|title|artist]] offers in a message, read the
  # way the page reads them (app/frontend/lib/song-reference.js): an offer is
  # a whole Markdown paragraph of its own (blank line or edge of the message
  # on both sides, outside any fenced code block), only the \\ \| \[ \]
  # escapes, the URL as its first field. A URL that merely contains another
  # one is a different offer. Stricter than the page where they disagree:
  # that only ever leaves a song without a suggester.
  OFFER_LINE = /\A\[\[song:([^\r\n]*)\]\][ \t]*\z/
  FENCE = /\A {0,3}(`{3,}|~{3,})/

  def self.offered_urls(content)
    lines = content.to_s.gsub("\r\n", "\n").split("\n", -1)
    fence = nil
    lines.each_with_index.filter_map do |line, index|
      if (opening = FENCE.match(line))
        marker = opening[1]
        if fence.nil? then fence = marker
        elsif marker[0] == fence[0] && marker.length >= fence.length && line.strip == marker then fence = nil
        end
        next
      end
      next if fence
      next unless (index.zero? || lines[index - 1].strip.empty?) &&
        (index == lines.size - 1 || lines[index + 1].strip.empty?)

      match = OFFER_LINE.match(line)
      fields = match && offer_fields(match[1])
      next unless fields
      # One bare field without a scheme is the legacy [[song:ID]] reference.
      next if fields.size == 1 && !fields.first.match?(/\A[A-Za-z][A-Za-z0-9+.-]*:/)

      fields.first.strip.presence
    end
  end

  # The |-separated fields of an offer, unescaped, or nil when the page would
  # not read it as an offer at all (an unknown escape, a bare bracket, more
  # than three fields).
  def self.offer_fields(body)
    fields = [ +"" ]
    chars = body.chars
    index = 0
    while index < chars.size
      char = chars[index]
      if char == "\\"
        index += 1
        char = chars[index]
        return nil unless char && "\\|[]".include?(char)
      elsif char == "|"
        fields << +""
        return nil if fields.size > 3
        index += 1
        next
      elsif "[]".include?(char)
        return nil
      end
      fields.last << char
      index += 1
    end
    fields
  end

  private

  def identity(value)
    return unless value

    [ value["provider"], value["embed_id"].presence || value["url"] ]
  end

end
