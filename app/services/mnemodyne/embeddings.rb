require "net/http"
require "timeout"

class Mnemodyne::Embeddings

  class Unavailable < StandardError; end

  def self.configured?
    ENV["MNEMODYNE_EMBEDDING_URL"].present? && profile.present?
  end

  def self.profile
    ENV["MNEMODYNE_EMBEDDING_PROFILE"]
  end

  def self.embed(text)
    raise Unavailable unless configured?
    uri = URI(ENV.fetch("MNEMODYNE_EMBEDDING_URL"))
    raise Unavailable unless uri.is_a?(URI::HTTP) && uri.userinfo.nil?
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{ENV['MNEMODYNE_EMBEDDING_TOKEN']}" if ENV["MNEMODYNE_EMBEDDING_TOKEN"].present?
    request.body = { input: text, model: profile }.to_json
    body = +""
    Timeout.timeout(2, Unavailable) do
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
        open_timeout: 0.5, read_timeout: 1, write_timeout: 1) do |http|
        http.request(request) do |response|
          raise Unavailable unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            raise Unavailable if body.bytesize + chunk.bytesize > 200_000
            body << chunk
          end
        end
      end
    end
    vector = JSON.parse(body).dig("data", 0, "embedding")
    raise Unavailable unless valid_vector?(vector)
    vector
  rescue Unavailable
    raise
  rescue StandardError
    # Do not expose provider responses, URLs, query text or network error details.
    raise Unavailable
  end

  def self.valid_vector?(vector)
    vector.is_a?(Array) && vector.length.between?(1, 4096) &&
      vector.all? { |value| value.is_a?(Numeric) && value.finite? && value.abs <= 1_000_000 } &&
      vector.any? { |value| value != 0 }
  end

  def self.cosine(a, b)
    return 0.0 unless a&.length == b&.length && a.present?
    dot = a.zip(b).sum { |x, y| x * y }
    norm = Math.sqrt(a.sum { |x| x * x } * b.sum { |x| x * x })
    norm.positive? ? (dot / norm).clamp(-1.0, 1.0) : 0.0
  end

end
