# A song file's length and its own tags (title, artist, album, year), read
# with ffprobe. Tags are untrusted text from the file: cleaned and cut to
# length. Empty hash values when ffprobe can't read the file.
module FieldSong::AudioProbe

  TIMEOUT = 30

  module_function

  def read(path)
    stdout, _stderr, status = Open3.capture3(
      "timeout", TIMEOUT.to_s,
      "ffprobe", "-v", "error", "-show_entries", "format=duration:format_tags:stream=codec_type",
      "-of", "json", path.to_s
    )
    return {} unless status.success?

    data = JSON.parse(stdout)
    return {} if Array(data["streams"]).none? { |stream| stream["codec_type"] == "audio" }

    tags = (data.dig("format", "tags") || {}).transform_keys { |key| key.to_s.downcase }
    seconds = Float(data.dig("format", "duration"), exception: false)
    year = tags["date"].to_s[/\A(\d{4})/, 1]&.to_i || tags["year"].to_s[/\A(\d{4})/, 1]&.to_i
    {
      duration_ms: ((seconds * 1000).round if seconds&.positive?),
      title: clean(tags["title"]),
      artist: clean(tags["artist"] || tags["album_artist"]),
      album: clean(tags["album"]),
      year: (year if year && year.between?(1000, 3000))
    }.compact
  rescue JSON::ParserError, Errno::ENOENT
    {}
  end

  def clean(value) = value.to_s.scrub("").delete("\u0000").squish.truncate(200).presence

end
