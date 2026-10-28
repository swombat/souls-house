# A copy of the recording for the transcript page's player (spec §7).
#
# Browsers seek an MP3 by estimate: Chrome and Firefox jump to a byte offset
# from the file's table of contents (100 entries, positions rounded to 1/256
# of the file) and label whatever audio is there with the time that was
# asked for. On a VBR MP3 of an hour the audio and the label can be ten or
# twenty seconds apart, so clicking a line plays someone else's words while
# the highlight runs through the right ones (RYEKMN, 2026-10-28: 14 s). MP4
# carries a sample table, so seeks into an AAC .m4a land within a frame.
#
# The original stays as uploaded: transcription, voice samples and their
# digests all read it. Only MP3 originals get a copy; other formats seek
# well enough as they are.
module FieldRecording::Playback

  # ffmpeg transcodes at roughly fifty times real time on the house; the
  # longest recording so far is four and a half hours.
  TIMEOUT = 20 * 60
  BITRATE = "96k"
  CONTENT_TYPE = "audio/mp4"

  module_function

  # Whether the player needs a copy of the file at `path`: true for MP3.
  def needed?(path)
    codec(path) == "mp3"
  end

  # The codec of the first audio stream, as ffprobe names it, or nil.
  def codec(path)
    stdout, _stderr, status = Open3.capture3(
      "timeout", FieldRecording::Probe::TIMEOUT.to_s,
      "ffprobe", "-v", "error", "-select_streams", "a:0",
      "-show_entries", "stream=codec_name", "-of", "json", path.to_s
    )
    return nil unless status.success?

    Array(JSON.parse(stdout)["streams"]).first&.dig("codec_name")
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  # Writes an AAC .m4a of the audio at `input` to `output`, with the index
  # at the front so the player can seek before the whole file has arrived.
  # True when ffmpeg finished.
  def transcode(input, output)
    _stdout, _stderr, status = Open3.capture3(
      "timeout", TIMEOUT.to_s,
      "ffmpeg", "-nostdin", "-loglevel", "error", "-y", "-i", input.to_s,
      "-vn", "-map_metadata", "-1", "-c:a", "aac", "-b:a", BITRATE, "-movflags", "+faststart",
      "-f", "mp4", output.to_s
    )
    status.success? && File.size?(output).present?
  rescue Errno::ENOENT
    false
  end

  # The copy's filename: the original's, with the extension the player sees.
  def filename_for(blob)
    "#{File.basename(blob.filename.to_s, '.*')}.m4a"
  end

end
