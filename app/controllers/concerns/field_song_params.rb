# What a request may set on a Field song, for the page and the API alike.
# Only the keys given are touched (an update can add lyrics without resending
# the rest). Text fields must be strings; links a list of addresses (or one);
# dated_at an ISO 8601 date; shared_for a person's key ("agent-abc",
# "user-abc") or their exact name, blank for nobody in particular.
module FieldSongParams

  class Invalid < StandardError; end

  TEXT_KEYS = %i[title artist album lyrics note].freeze
  BOOLEAN = ActiveModel::Type::Boolean.new

  private

  def field_song_attributes(source, account:)
    attributes = {}
    TEXT_KEYS.each do |key|
      next unless source.key?(key)

      value = source[key]
      raise Invalid, "#{key} must be text" unless value.nil? || value.is_a?(String)

      attributes[key] = value
    end

    if source.key?(:year)
      year = source[:year].to_s.strip
      raise Invalid, "year must be a year, like 1997" unless year.empty? || year.match?(/\A\d{4}\z/)

      attributes[:year] = year.empty? ? nil : year.to_i
    end

    attributes[:links] = song_links(source[:links]) if source.key?(:links)
    attributes[:instrumental] = BOOLEAN.cast(source[:instrumental]) || false if source.key?(:instrumental)
    # Words given for a song once said to be instrumental: it has words after all.
    attributes[:instrumental] = false if attributes[:lyrics].present? && !source.key?(:instrumental)
    attributes[:dated_at] = FieldDate.parse_or_clear(source[:dated_at], param: "dated_at") if source.key?(:dated_at)
    attributes[:shared_for] = FieldSong.find_recipient(account, source[:shared_for]) if source.key?(:shared_for)
    attributes
  rescue FieldDate::Invalid, FieldSong::UnknownRecipient => e
    raise Invalid, e.message
  end

  def song_links(value)
    list = case value
    when nil, "" then []
    when String then [ value ]
    when Array then value
    when ActionController::Parameters then value.values
    else raise Invalid, "links must be a list of web addresses"
    end
    raise Invalid, "links must be a list of web addresses" unless list.all? { |item| item.is_a?(String) }

    list
  end

  # Attach an audio file from this request only (never a signed blob id: see
  # FieldFile::Upload).
  def attach_song_audio(song, value)
    return if value.blank?
    raise Invalid, "audio must be a multipart file upload" unless FieldFile::Upload.uploaded_file?(value)

    song.audio.attach(value)
  end

end
