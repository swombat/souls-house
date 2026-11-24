require "net/http"
require "openssl"
require "timeout"

class Mnemodyne::Embeddings

  # Why an embedding could not be had, from a closed set, so a failed job or
  # an error report can say Voyage from us. It carries only the reason, an
  # integer HTTP status and an exception class name: never a URL, host,
  # response body, query text or exception message.
  class Unavailable < StandardError

    REASONS = %i[
      not_configured timeout rate_limited http_status body_too_large
      invalid_response bad_endpoint network unexpected
    ].freeze

    attr_reader :reason, :status, :error_class

    def initialize(reason = :unexpected, status: nil, error_class: nil)
      @reason = REASONS.include?(reason) ? reason : :unexpected
      @status = status if status.is_a?(Integer)
      @error_class = error_class if error_class.is_a?(String) && error_class.match?(/\A[A-Z][A-Za-z0-9_:]*\z/)
      detail = [ @status, @error_class ].compact.join(", ")
      super("Mnemodyne embeddings unavailable: #{@reason}#{" (#{detail})" if detail.present?}")
    end

    def context
      { reason: reason, status: status, error_class: error_class }.compact
    end

  end

  class Busy < StandardError

    attr_reader :status

    def initialize(status = nil)
      @status = status
      super("busy")
    end

  end

  # The outer deadline, kept apart from Net's own timeouts only so the two
  # can be told apart in a test; both are reported as :timeout.
  class Deadline < StandardError; end
  private_constant :Deadline

  NETWORK_ERRORS = [
    SocketError, SystemCallError, IOError, OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse
  ].freeze

  # Recall sits on the wake path, so both attempts share this one cap.
  OVERALL_SECONDS = 2
  # A batch (re-embedding a vault) is off the wake path and may take longer.
  BATCH_SECONDS = 30
  BATCH_SIZE = 32
  RETRY_JITTER = 0.05..0.25
  MINIMUM_RETRY_SECONDS = 0.2
  MAXIMUM_BODY_BYTES = 200_000
  # Voyage (MongoDB) is the hosted embedder: a profile named voyage-* is that
  # model, at its default dimension, called with the house's credential.
  # Choosing it was a private-data disclosure decision (Daniel, 9 Nov 2026).
  VOYAGE_URL = "https://api.voyageai.com/v1/embeddings"
  INPUT_TYPES = { document: "document", query: "query" }.freeze

  def self.configured?
    return voyage_key.present? if voyage?
    ENV["MNEMODYNE_EMBEDDING_URL"].present? && profile.present?
  end

  def self.profile
    ENV["MNEMODYNE_EMBEDDING_PROFILE"]
  end

  def self.voyage?
    profile.to_s.match?(/\Avoyage-[a-z0-9.-]+\z/)
  end

  # Whether one request may carry many texts (the private accessory takes one).
  def self.batched?
    voyage?
  end

  def self.voyage_key
    Rails.application.credentials.dig(:voyage, :api_key).presence
  end

  # input_type :document for what is stored, :query for what is searched with.
  def self.embed(text, input_type: :document)
    embed_many([ text ], input_type: input_type, seconds: OVERALL_SECONDS).first
  end

  def self.embed_many(texts, input_type: :document, seconds: BATCH_SECONDS)
    raise Unavailable.new(:not_configured) unless configured?
    raise ArgumentError unless texts.is_a?(Array) && texts.length.between?(1, BATCH_SIZE) && texts.all?(String)
    raise ArgumentError unless INPUT_TYPES.key?(input_type)
    raise ArgumentError if texts.length > 1 && !batched?
    uri, request = voyage? ? voyage_request(texts, input_type) : accessory_request(texts.first)
    limit = MAXIMUM_BODY_BYTES * texts.length
    deadline = monotonic + seconds
    body = nil
    Timeout.timeout(seconds, Deadline) do
      attempts = 0
      begin
        attempts += 1
        body = fetch(uri, request, limit, read_timeout: [ seconds - 0.1, 1.9 ].max)
      rescue Busy => busy
        # One best-effort retry inside the same budget: a wake burst can land
        # while the server's single slot is taken (#804), or Voyage can rate
        # limit. Never a third try, never past the deadline, and not at all
        # when too little is left.
        raise Unavailable.new(:rate_limited, status: busy.status), cause: nil if attempts > 1
        pause = rand(RETRY_JITTER)
        raise Unavailable.new(:rate_limited, status: busy.status), cause: nil if deadline - monotonic < pause + MINIMUM_RETRY_SECONDS
        sleep(pause)
        retry
      end
    end
    vectors = parse_vectors(body, texts.length)
    raise Unavailable.new(:invalid_response) unless vectors.all? { |vector| valid_vector?(vector) } && vectors.map(&:length).uniq.one?
    vectors
  rescue Unavailable
    raise
  # Do not expose provider responses, URLs, query text or network error
  # details: only the reason and the class name travel, and never the cause.
  rescue Deadline, Timeout::Error => error
    raise Unavailable.new(:timeout, error_class: (error.class.name unless error.is_a?(Deadline))), cause: nil
  rescue JSON::ParserError => error
    raise Unavailable.new(:invalid_response, error_class: error.class.name), cause: nil
  rescue URI::Error => error
    raise Unavailable.new(:bad_endpoint, error_class: error.class.name), cause: nil
  rescue *NETWORK_ERRORS => error
    raise Unavailable.new(:network, error_class: error.class.name), cause: nil
  rescue StandardError => error
    raise Unavailable.new(:unexpected, error_class: error.class.name), cause: nil
  end

  def self.accessory_request(text)
    uri = URI(ENV.fetch("MNEMODYNE_EMBEDDING_URL"))
    raise Unavailable.new(:bad_endpoint) unless uri.is_a?(URI::HTTP) && uri.userinfo.nil?
    private_hosts = %w[souls-house-embeddings localhost 127.0.0.1 ::1]
    raise Unavailable.new(:bad_endpoint) unless uri.scheme == "https" || private_hosts.include?(uri.host)
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{ENV['MNEMODYNE_EMBEDDING_TOKEN']}" if ENV["MNEMODYNE_EMBEDDING_TOKEN"].present?
    request.body = { input: text, model: profile }.to_json
    [ uri, request ]
  end
  private_class_method :accessory_request

  def self.voyage_request(texts, input_type)
    uri = URI(VOYAGE_URL)
    request = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
    request["Authorization"] = "Bearer #{voyage_key}"
    request.body = { input: texts, model: profile, input_type: INPUT_TYPES.fetch(input_type) }.to_json
    [ uri, request ]
  end
  private_class_method :voyage_request

  # Each vector must land on its own text: Voyage lists data[i].index, and the
  # indexes must be exactly 0...count (no duplicates, gaps or strays), or the
  # whole answer is refused. A single unindexed answer is the accessory's shape.
  def self.parse_vectors(body, count)
    data = JSON.parse(body)["data"]
    raise Unavailable.new(:invalid_response) unless data.is_a?(Array) && data.length == count && data.all?(Hash)
    return [ data.first["embedding"] ] if count == 1 && !data.first.key?("index")
    indexes = data.map { |row| row["index"] }
    raise Unavailable.new(:invalid_response) unless indexes.all?(Integer) && indexes.sort == (0...count).to_a
    data.sort_by { |row| row["index"] }.map { |row| row["embedding"] }
  end
  private_class_method :parse_vectors

  def self.fetch(uri, request, limit = MAXIMUM_BODY_BYTES, read_timeout: 1.9)
    body = +""
    busy = nil
    # The server waits up to 1.5 s for its one slot before inferring, so the
    # read timeout covers that wait; the outer cap still bounds the whole call.
    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
      open_timeout: 0.5, read_timeout: read_timeout, write_timeout: 1) do |http|
      http.request(request) do |response|
        if response.is_a?(Net::HTTPServiceUnavailable) || response.is_a?(Net::HTTPTooManyRequests)
          busy = response.code.to_i
          # Drain the 503/429 so the connection closes cleanly, under the same size cap.
          drained = 0
          response.read_body do |chunk|
            drained += chunk.bytesize
            raise Unavailable.new(:body_too_large, status: busy) if drained > MAXIMUM_BODY_BYTES
          end
          next
        end
        raise Unavailable.new(:http_status, status: response.code.to_i) unless response.is_a?(Net::HTTPSuccess)
        response.read_body do |chunk|
          raise Unavailable.new(:body_too_large) if body.bytesize + chunk.bytesize > limit
          body << chunk
        end
      end
    end
    raise Busy.new(busy) if busy
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

  # Recall scores every node in a vault on the wake path, so this is one pass
  # with no intermediate arrays: at 1024 dimensions zip/sum took ~1 s for a
  # 1,055-node vault, this takes ~50 ms for the same values.
  def self.cosine(a, b)
    return 0.0 unless a&.length == b&.length && a.present?
    dot = 0.0
    norm_a = 0.0
    norm_b = 0.0
    i = 0
    length = a.length
    while i < length
      x = a[i]
      y = b[i]
      dot += x * y
      norm_a += x * x
      norm_b += y * y
      i += 1
    end
    norm = Math.sqrt(norm_a * norm_b)
    norm.positive? ? (dot / norm).clamp(-1.0, 1.0) : 0.0
  end

end
