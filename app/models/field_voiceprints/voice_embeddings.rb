require "net/http"
require "timeout"

# Client for the house's own speaker-embedding service (services/voice-embeddings,
# spec docs/2026-10-19-field-voiceprints-in-house.md §3). It takes a WAV that
# FieldVoiceprints::Sample.cut produced and returns a 192-d ECAPA embedding and
# the profile that made it. Nothing else talks to the service, and audio only
# travels on the house's private network.
#
# Errors never carry the URL, the response body or the network detail.
class FieldVoiceprints::VoiceEmbeddings

  class Unavailable < StandardError; end

  DIMENSIONS = 192
  MAX_AUDIO_BYTES = 8 * 1024 * 1024
  MAX_RESPONSE_BYTES = 64_000
  PRIVATE_HOSTS = %w[souls-house-voice-embeddings localhost 127.0.0.1 ::1].freeze

  Result = Data.define(:embedding, :profile)
  Health = Data.define(:ready, :profile, :dimensions)

  def self.configured?
    ENV["VOICE_EMBEDDING_URL"].present? && ENV["VOICE_EMBEDDING_TOKEN"].to_s.length >= 24
  end

  def self.health
    body = request(Net::HTTP::Get, "/health", deadline: 5)
    raise Unavailable unless body["ready"] == true && body["dimensions"] == DIMENSIONS && valid_profile?(body["profile"])
    Health.new(ready: true, profile: body["profile"], dimensions: DIMENSIONS)
  end

  def self.embed(wav)
    raise Unavailable unless wav.is_a?(String) && wav.bytesize.between?(1, MAX_AUDIO_BYTES)
    body = request(Net::HTTP::Post, "/embed", deadline: 90) do |post|
      post["Content-Type"] = "audio/wav"
      post.body = wav
    end
    vector = body["embedding"]
    raise Unavailable unless valid_vector?(vector) && valid_profile?(body["profile"])
    Result.new(embedding: vector.map(&:to_f), profile: body["profile"])
  end

  def self.request(klass, path, deadline:)
    raise Unavailable unless configured?
    base = URI(ENV.fetch("VOICE_EMBEDDING_URL"))
    raise Unavailable unless base.is_a?(URI::HTTP) && base.userinfo.nil?
    raise Unavailable unless base.scheme == "https" || PRIVATE_HOSTS.include?(base.host)
    uri = base.dup
    uri.path = path
    req = klass.new(uri)
    req["Authorization"] = "Bearer #{ENV['VOICE_EMBEDDING_TOKEN']}"
    yield req if block_given?
    body = +""
    Timeout.timeout(deadline, Unavailable) do
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: 1, read_timeout: deadline, write_timeout: 10) do |http|
        http.request(req) do |response|
          raise Unavailable unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            raise Unavailable if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
            body << chunk
          end
        end
      end
    end
    parsed = JSON.parse(body)
    raise Unavailable unless parsed.is_a?(Hash)
    parsed
  rescue Unavailable
    raise
  rescue StandardError
    raise Unavailable, cause: nil
  end
  private_class_method :request

  def self.valid_vector?(vector)
    vector.is_a?(Array) && vector.length == DIMENSIONS &&
      vector.all? { |value| value.is_a?(Numeric) && value.finite? && value.abs <= 1_000 } &&
      vector.any? { |value| value != 0 }
  end

  def self.valid_profile?(profile)
    profile.is_a?(String) && profile.match?(/\Aecapa-[A-Za-z0-9.+_-]{1,120}\z/)
  end

end
