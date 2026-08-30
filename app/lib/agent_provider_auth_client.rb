class AgentProviderAuthClient

  class Error < StandardError

    attr_reader :status, :body

    def initialize(message, status: nil, body: nil)
      super(message)
      @status = status
      @body = body
    end

  end

  def initialize(agent)
    require "net/http"

    @agent = agent
  end

  def capabilities
    request(:get, "/auth/capabilities")
  end

  def status(provider:)
    request(:get, "/auth/status", provider:)
  end

  def usage(provider:, model:, refresh: false)
    request(:get, "/auth/usage", provider:, model:, refresh: refresh ? 1 : nil)
  end

  def start(provider:)
    request(:post, "/auth/start", provider:)
  end

  def cancel(provider:)
    request(:post, "/auth/cancel", provider:)
  end

  def submit_code(provider:, code:)
    request(:post, "/auth/code", provider:, code:)
  end

  def disconnect(provider:)
    request(:post, "/auth/disconnect", provider:)
  end

  private

  attr_reader :agent

  def request(method, path, payload = nil)
    raise Error, "Agent runtime is not available" if agent.trigger_bearer_token.blank?

    uri = URI("#{Agents::Endpoint.url_for(agent).delete_suffix("/")}#{path}")
    uri.query = URI.encode_www_form(payload.compact) if method == :get && payload.present?
    request_class = method == :get ? Net::HTTP::Get : Net::HTTP::Post
    http_request = request_class.new(uri)
    http_request["Authorization"] = "Bearer #{agent.trigger_bearer_token}"
    http_request["Content-Type"] = "application/json"
    http_request.body = payload.to_json if method != :get && payload.present?

    response = Net::HTTP.start(
      uri.hostname,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 5,
      read_timeout: 20
    ) { |http| http.request(http_request) }
    body = JSON.parse(response.body)
    return body if response.is_a?(Net::HTTPSuccess)

    raise Error.new(body["error"].presence || "Provider authentication request failed", status: response.code.to_i, body:)
  rescue JSON::ParserError
    raise Error.new("Agent runtime returned an invalid authentication response", status: response&.code&.to_i)
  rescue SystemCallError, Timeout::Error, SocketError => e
    raise Error, "Could not reach agent runtime: #{e.message}"
  end

end
