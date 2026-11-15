# Reads a recording's duration with ffprobe (spec §4). nil when the file has
# no audio stream we can read.
module FieldRecording::Probe

  TIMEOUT = 60

  module_function

  def duration_ms(path)
    stdout, _stderr, status = Open3.capture3(
      "timeout", TIMEOUT.to_s,
      "ffprobe", "-v", "error", "-select_streams", "a",
      "-show_entries", "stream=codec_type:format=duration", "-of", "json", path.to_s
    )
    return nil unless status.success?

    data = JSON.parse(stdout)
    return nil if Array(data["streams"]).none? { |stream| stream["codec_type"] == "audio" }

    seconds = Float(data.dig("format", "duration"), exception: false)
    seconds&.positive? ? (seconds * 1000).round : nil
  rescue JSON::ParserError, Errno::ENOENT
    nil
  end

  # For files whose container carries no duration (a browser's streamed WebM):
  # the last audio packet's timestamp. Reads the file without decoding it.
  def packet_duration_ms(path)
    stdout, _stderr, status = Open3.capture3(
      "timeout", TIMEOUT.to_s,
      "ffprobe", "-v", "error", "-select_streams", "a:0",
      "-show_entries", "packet=pts_time", "-of", "csv=p=0", path.to_s
    )
    return nil unless status.success?

    seconds = stdout.lines.reverse_each.lazy.filter_map { |line| Float(line.strip, exception: false) }.first
    seconds&.positive? ? (seconds * 1000).round : nil
  rescue Errno::ENOENT
    nil
  end

end
