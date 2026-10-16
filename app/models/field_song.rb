# A song someone shared in an account's Field: where to hear it (a link to
# Spotify, YouTube and the like, and/or an audio file), its words, why it was
# shared, and for whom. Most residents can't hear the music, so for them the
# song is the lyrics, the note and the act of sharing; all of it is kept.
#
# A song has to be hearable: a link or a file. The lyrics may come later; until
# they do (or someone says it is instrumental) it waits in Needs you, and both
# the page and the API say the words are missing. A lookup's lyrics are only
# ever a suggestion: nothing here fetches or saves them by itself.
#
# Deleting discards, as for every Field item.
#
# added_by is whoever put the song in the Field: the person who clicked the
# button, or the resident who added it through the API. suggested_by is the
# resident whose message offered it, when it came in through Add to Field.
class FieldSong < ApplicationRecord

  include Discard::Model
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include FieldTaggable

  MAX_LINKS = 4
  MAX_LYRICS = 20_000
  MAX_NOTE = 2_000
  MAX_AUDIO_BYTES = 50.megabytes
  MAX_AUDIO_LABEL = "50 MB"
  AUDIO_TYPES = %w[
    audio/mpeg audio/mp3 audio/mp4 audio/x-m4a audio/m4a audio/aac audio/ogg audio/opus
    audio/wav audio/x-wav audio/wave audio/flac audio/x-flac audio/webm
  ].freeze
  AUDIO_EXTENSIONS = %w[mp3 m4a mp4 aac ogg oga opus wav flac webm].freeze
  LYRICS_STATES = %w[present missing instrumental].freeze

  belongs_to :account
  belongs_to :added_by, polymorphic: true, optional: true
  belongs_to :suggested_by, polymorphic: true, optional: true
  belongs_to :shared_for, polymorphic: true, optional: true

  has_one_attached :audio

  before_validation :normalise
  before_validation :read_audio_tags, if: -> { attachment_changes["audio"].present? }

  validates :title, presence: true, length: { maximum: 200 }
  validates :artist, :album, length: { maximum: 200 }
  validates :year, numericality: { only_integer: true, in: 1000..3000 }, allow_nil: true
  validates :lyrics, length: { maximum: MAX_LYRICS }
  validates :note, length: { maximum: MAX_NOTE }
  validate :hearable
  validate :links_valid
  validate :audio_bounded
  validate :instrumental_without_lyrics
  validate :shared_for_in_account
  validate :suggested_by_in_account

  broadcasts_to :account

  scope :newest_first, -> { order(Arel.sql("COALESCE(field_songs.dated_at, field_songs.created_at) DESC"), id: :desc) }
  # Waiting for its words: not said to be instrumental, and no lyrics yet.
  WAITING_SQL = "field_songs.instrumental = FALSE AND (field_songs.lyrics IS NULL OR field_songs.lyrics !~ '[^[:space:]]')"
  scope :lyrics_missing, -> { where(WAITING_SQL) }

  def lyrics_state
    return "instrumental" if instrumental

    lyrics.to_s.strip.empty? ? "missing" : "present"
  end

  def lyrics_missing? = lyrics_state == "missing"

  def added_by_name = FieldSong.person_name(added_by)
  def added_by_kind = FieldSong.person_kind(added_by)
  def suggested_by_name = FieldSong.person_name(suggested_by)
  def suggested_by_kind = FieldSong.person_kind(suggested_by)
  def shared_for_name = FieldSong.person_name(shared_for)
  def shared_for_kind = FieldSong.person_kind(shared_for)

  def added_by_agent?(agent)
    agent.present? && added_by_type == "Agent" && added_by_id == agent.id
  end

  def suggested_by_agent?(agent)
    agent.present? && suggested_by_type == "Agent" && suggested_by_id == agent.id
  end

  def self.person_name(person)
    case person
    when User then person.full_name.presence || person.email_address.split("@").first
    when Agent then person.name
    end
  end

  def self.person_kind(person)
    case person
    when User then "human"
    when Agent then "resident"
    end
  end

  # "user-abc" / "agent-abc": how the page and the API name a person a song
  # can be for.
  def self.person_key(person)
    case person
    when User then "user-#{person.to_param}"
    when Agent then "agent-#{person.to_param}"
    end
  end

  # Who a song in this account can be for: its human members and its
  # residents.
  def self.recipients(account)
    users = account.users.order(:id).to_a
    agents = account.agents.order(:id).to_a
    (users + agents).map { |person| { key: person_key(person), name: person_name(person), kind: person_kind(person) } }
  end

  class UnknownRecipient < StandardError; end

  # A person or resident of the account from a key ("agent-abc") or an exact
  # name (case-insensitive). nil for blank. Raises UnknownRecipient when it
  # matches nobody, or more than one by name.
  def self.find_recipient(account, value)
    value = value.to_s.strip
    return nil if value.empty?

    kind, id = value.split("-", 2)
    if id.present? && (kind == "user" || kind == "agent")
      scope = kind == "user" ? account.users : account.agents
      found = scope.find_by_obfuscated_id(id) rescue nil
      return found if found
    end

    matches = (account.users.to_a + account.agents.to_a).select { |person| person_name(person).to_s.casecmp?(value) }
    raise UnknownRecipient, "Nobody in this account is called #{value.truncate(60)}" if matches.empty?
    raise UnknownRecipient, "More than one person here is called #{value.truncate(60)}; use their key" if matches.size > 1

    matches.first
  end

  # Links as given; normalise drops those that aren't web addresses and
  # remembers them here so the error can say which.
  def links=(value)
    list = Array(value).flat_map { |item| item.is_a?(String) ? item.split(/\s+/) : [ item ] }.compact_blank
    @invalid_links = list.filter_map do |item|
      url = item.is_a?(Hash) ? (item["url"] || item[:url]).to_s : item.to_s
      url unless FieldSong::Links.web_url?(url)
    end
    super(list.select { |item| FieldSong::Links.web_url?(item.is_a?(Hash) ? (item["url"] || item[:url]).to_s : item.to_s) })
  end

  def audio_filename = audio.attached? ? audio.filename.to_s : nil
  def audio_content_type = audio.attached? ? audio.content_type : nil
  def audio_byte_size = audio.attached? ? audio.byte_size : nil

  private

  def normalise
    self.title = FieldSong.clean_line(title)
    self.artist = FieldSong.clean_line(artist).presence
    self.album = FieldSong.clean_line(album).presence
    self.note = note.to_s.scrub("").delete("\u0000").strip.presence
    # Line breaks are the shape of a lyric: kept, only Windows endings and
    # outer blank space go.
    self.lyrics = lyrics.to_s.scrub("").delete("\u0000").gsub("\r\n", "\n").gsub("\r", "\n").strip.presence
    # Written straight to the column: the links= writer would forget which
    # addresses it refused.
    self[:links] = FieldSong::Links.normalise_list(links)
  end

  def self.clean_line(value) = value.to_s.scrub("").delete("\u0000").squish

  # Fill what the person left blank from the file's own tags, and read its
  # length. Tags are suggestions from the file, so they never replace what
  # someone typed.
  def read_audio_tags
    path = FieldSong.attachable_path(attachment_changes["audio"].attachable)
    return unless path

    info = FieldSong::AudioProbe.read(path)
    self.duration_ms = info[:duration_ms]
    self.title = info[:title] if title.blank? && info[:title].present?
    self.artist = info[:artist] if artist.blank? && info[:artist].present?
    self.album = info[:album] if album.blank? && info[:album].present?
    self.year = info[:year] if year.nil? && info[:year]
    # Last, the file's name: only where neither the person nor the tags
    # said anything. "Jeff Buckley - Hallelujah.mp3" gives both.
    if title.blank?
      name = File.basename(audio.filename.to_s, ".*").tr("_", " ").sub(/\A\d{1,3}[\s.-]+/, "").squish
      guessed_artist, guessed_title = FieldSongLookup.split_title(name)
      self.title = guessed_title.to_s.truncate(200).presence || name.truncate(200).presence
      self.artist = guessed_artist.truncate(200) if artist.blank? && guessed_artist
    end
  end

  def self.attachable_path(attachable)
    if attachable.respond_to?(:tempfile) then attachable.tempfile&.path
    elsif attachable.respond_to?(:path) then attachable.path
    elsif attachable.is_a?(Hash) && attachable[:io].respond_to?(:path) then attachable[:io].path
    end
  end

  def hearable
    return if links.any? || audio.attached?

    errors.add(:base, "Add a link (Spotify, YouTube…) or an audio file, so the song can be heard")
  end

  def links_valid
    errors.add(:links, "can be at most #{MAX_LINKS}") if links.size > MAX_LINKS
    @invalid_links&.each { |url| errors.add(:links, "#{url.truncate(80)} isn't a web address") }
  end

  def audio_bounded
    return unless audio.attached?

    errors.add(:audio, "must be #{MAX_AUDIO_LABEL} or smaller") if audio.byte_size > MAX_AUDIO_BYTES
    extension = File.extname(audio.filename.to_s).delete(".").downcase
    unless AUDIO_TYPES.include?(audio.content_type.to_s) || AUDIO_EXTENSIONS.include?(extension)
      errors.add(:audio, "must be an audio file (#{AUDIO_EXTENSIONS.join(", ")})")
    end
  end

  def instrumental_without_lyrics
    errors.add(:instrumental, "can't be set on a song with lyrics") if instrumental && lyrics.present?
  end

  def shared_for_in_account
    return if shared_for.nil?

    errors.add(:shared_for, "must be someone in this account") unless in_account?(shared_for)
  end

  def suggested_by_in_account
    return if suggested_by.nil?

    errors.add(:suggested_by, "must be someone in this account") unless in_account?(suggested_by)
  end

  def in_account?(person)
    case person
    when User then account&.users&.exists?(person.id)
    when Agent then person.account_id == account_id
    else false
    end
  end

end
