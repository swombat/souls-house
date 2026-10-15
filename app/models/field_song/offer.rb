# An outside link can be offered without looking anything up or copying the
# conversation into the Field. Stricter than ordinary Field links on purpose.
class FieldSong::Offer

  class InvalidLink < StandardError; end

  attr_reader :link

  def initialize(account:, url:)
    @account = account
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

  def save!(title:, artist:, by:)
    song = @account.field_songs.new(title: title, artist: artist, links: [ link ], added_by: by)
    song.validate!

    # A transaction alone permits two requests to both observe no match.
    # Every offer writer takes this same account row lock before looking.
    @account.with_lock do
      existing_song || song.tap(&:save!)
    end
  end

  private

  def identity(value)
    return unless value

    [ value["provider"], value["embed_id"].presence || value["url"] ]
  end

end
