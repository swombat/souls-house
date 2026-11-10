require "test_helper"
require "open3"

# The gain step on Listen audio (eOyXXJ), run through the real ffmpeg on
# generated tones: it raises by the gain, its ceiling stays at 0.95 (alimiter
# would otherwise level back up to 0 dBFS), and zero gain never runs ffmpeg.
class AudioGainTest < ActiveSupport::TestCase

  def tone(amplitude)
    out, _err, status = Open3.capture3("ffmpeg", "-nostdin", "-loglevel", "error", "-f", "lavfi",
      "-i", "aevalsrc=#{amplitude}*sin(2*PI*440*t):s=44100:d=1", "-c:a", "libmp3lame", "-b:a", "128k", "-f", "mp3", "pipe:1",
      binmode: true)
    assert status.success?
    out
  end

  def peak_db(mp3)
    _out, err, _status = Open3.capture3("ffmpeg", "-nostdin", "-f", "mp3", "-i", "pipe:0", "-af", "volumedetect", "-f", "null", "-",
      stdin_data: mp3, binmode: true)
    err[/max_volume: (-?[\d.]+) dB/, 1].to_f
  end

  test "zero gain returns the audio untouched without running ffmpeg" do
    Open3.stub(:capture3, ->(*) { flunk "ffmpeg ran" }) do
      assert_equal "ID3same", AudioGain.apply("ID3same", 0)
      assert_equal "ID3same", AudioGain.apply("ID3same", nil)
    end
  end

  test "a quiet render is raised by the gain" do
    quiet = tone(0.02)
    before = peak_db(quiet)
    after = peak_db(AudioGain.apply(quiet, 10))
    assert_in_delta before + 10, after, 1.0
  end

  test "a loud render is limited at 0.95, not levelled back up to full scale" do
    louder = AudioGain.apply(tone(0.5), 10)
    peak = peak_db(louder)
    assert_operator peak, :<, -0.2, "peak #{peak} dB: the limiter levelled up"
    assert_operator peak, :>, -1.5
  end

  test "a failed ffmpeg run is an error, not silence" do
    assert_raises(AudioGain::Failed) { AudioGain.apply("not audio at all", 6) }
  end

  def duration(mp3)
    _out, err, _status = Open3.capture3("ffmpeg", "-nostdin", "-f", "mp3", "-i", "pipe:0", "-f", "null", "-",
      stdin_data: mp3, binmode: true)
    h, m, s = err.scan(/time=(\d+):(\d+):([\d.]+)/).last
    h.to_i * 3600 + m.to_i * 60 + s.to_f
  end

  def pitch_hz(mp3)
    raw, _err, _status = Open3.capture3("ffmpeg", "-nostdin", "-loglevel", "error", "-f", "mp3", "-i", "pipe:0",
      "-ac", "1", "-ar", "44100", "-f", "s16le", "pipe:1", stdin_data: mp3, binmode: true)
    samples = raw.unpack("s<*")[4410, 22050]
    crossings = samples.each_cons(2).count { |a, b| a.negative? && !b.negative? }
    crossings / (samples.size / 44100.0)
  end

  test "the filter: tempo first, then gain and limiter; each only when set" do
    assert_equal "atempo=0.930,volume=+10.00dB,alimiter=limit=0.95:level=disabled", AudioGain.filter(10, tempo: 0.93)
    assert_equal "atempo=0.930", AudioGain.filter(0, tempo: 0.93)
    assert_equal "volume=+10.00dB,alimiter=limit=0.95:level=disabled", AudioGain.filter(10)
    assert_equal "volume=+10.00dB,alimiter=limit=0.95:level=disabled", AudioGain.filter(10, tempo: 1.0)
  end

  test "tempo 1 with no gain never runs ffmpeg" do
    Open3.stub(:capture3, ->(*) { flunk "ffmpeg ran" }) do
      assert_equal "ID3same", AudioGain.apply("ID3same", 0, tempo: 1.0)
      assert_equal "ID3same", AudioGain.apply("ID3same", 0, tempo: nil)
    end
  end

  test "tempo slows the audio without lowering its pitch" do
    source = tone(0.5)
    slowed = AudioGain.apply(source, 0, tempo: 0.8)
    assert_in_delta duration(source) / 0.8, duration(slowed), 0.1
    assert_in_delta 440, pitch_hz(slowed), 15
  end

end
