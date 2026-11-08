require "net/http"
require "timeout"

class Mnemodyne::Embeddings

  class Unavailable < StandardError; end
  class Busy < StandardError; end

  # Recall sits on the wake path, so both attempts share this one cap.
  OVERALL_SECONDS = 2
  RETRY_JITTER = 0.05..0.25
  MINIMUM_RETRY_SECONDS = 0.2

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
    private_hosts = %w[souls-house-embeddings localhost 127.0.0.1 ::1]
    raise Unavailable unless uri.scheme == "https" || private_hosts.include?(uri.host)
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{ENV['MNEMODYNE_EMBEDDING_TOKEN']}" if ENV["MNEMODYNE_EMBEDDING_TOKEN"].present?
    request.body = { input: text, model: profile }.to_json
    deadline = monotonic + OVERALL_SECONDS
    body = nil
    Timeout.timeout(OVERALL_SECONDS, Unavailable) do
      attempts = 0
      begin
        attempts += 1
        body = fetch(uri, request)
      rescue Busy
        # One best-effort retry inside the same budget: a wake burst can land
        # while the server's single slot is taken (#804). Never a third try,
        # never past the deadline, and not at all when too little is left.
        raise Unavailable if attempts > 1
        pause = rand(RETRY_JITTER)
        raise Unavailable if deadline - monotonic < pause + MINIMUM_RETRY_SECONDS
        sleep(pause)
        retry
      end
    end
    vector = JSON.parse(body).dig("data", 0, "embedding")
    raise Unavailable unless valid_vector?(vector)
    vector
  rescue Unavailable
    raise
  rescue StandardError
    # Do not expose provider responses, URLs, query text or network error details.
    raise Unavailable, cause: nil
  end

  def self.fetch(uri, request)
    body = +""
    busy = false
    # The server waits up to 1.5 s for its one slot before inferring, so the
    # read timeout covers that wait; the outer cap still bounds the whole call.
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: 0.5, read_timeout: 1.9, write_timeout: 1) do |http|
      http.request(request) do |response|
        if response.is_a?(Net::HTTPServiceUnavailable)
          busy = true
          response.read_body { |_chunk| } # drain the small 503 so the connection closes cleanly
          next
        end
        raise Unavailable unless response.is_a?(Net::HTTPSuccess)
        response.read_body do |chunk|
          raise Unavailable if body.bytesize + chunk.bytesize > 200_000
          body << chunk
        end
      end
    end
    raise Busy if busy
    body
  end
  private_class_method :fetch

  def self.monotonic
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
  private_class_method :monotonic

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
