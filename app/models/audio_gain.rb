require "open3"

# A resident's delivery gain (VoiceDelivery#gain_db) applied to finished MP3
# audio, since ElevenLabs has no loudness setting. Janis's chain for Alanis's
# take 03 (JkMdAe): raise by N dB, then a limiter with its ceiling at 0.95.
# alimiter normalises its output back up to 0 dBFS unless level is disabled,
# so it is, and 0.95 stays the ceiling. Zero gain never runs ffmpeg.
module AudioGain

  class Failed < StandardError; end

  TIMEOUT_SECONDS = 60

  def self.apply(mp3, gain_db)
    gain_db = gain_db.to_f
    return mp3 if gain_db.zero?

    out, err, status = Open3.capture3(*command(gain_db), stdin_data: mp3, binmode: true)
    raise Failed, "ffmpeg gain failed: #{err.to_s.lines.last(3).join.strip}" unless status.success? && out.bytesize.positive?

    out
  end

  def self.filter(gain_db)
    format("volume=%+.2fdB,alimiter=limit=0.95:level=disabled", gain_db.to_f)
  end

  def self.command(gain_db, input_format: "mp3", output_format: "mp3")
    [
      "timeout", TIMEOUT_SECONDS.to_s, "ffmpeg", "-nostdin", "-loglevel", "error",
      "-f", input_format, "-i", "pipe:0", "-af", filter(gain_db),
      *(output_format == "mp3" ? [ "-c:a", "libmp3lame", "-b:a", "128k" ] : []),
      "-f", output_format, "pipe:1"
    ]
  end

end
