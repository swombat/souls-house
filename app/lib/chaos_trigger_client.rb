class ChaosTriggerClient

  DEFAULT_RUNTIME_TIMEOUT_SECS = 30.minutes.to_i
  DEFAULT_READ_TIMEOUT_SECS = DEFAULT_RUNTIME_TIMEOUT_SECS + 30

  def initialize(endpoint_url, trigger_bearer_token)
    require "net/http"

    @endpoint_url = endpoint_url
    @trigger_bearer_token = trigger_bearer_token
  end

  def request_response(conversation_id:, requested_by:, session_id:, request:, trigger_kind: "conversation", provider: nil, model: nil, reasoning_effort: nil, auth_mode: nil, request_delta: nil, persistent_session: false, trigger_payload: nil, activity: nil, read_timeout: DEFAULT_READ_TIMEOUT_SECS, runtime_timeout_secs: DEFAULT_RUNTIME_TIMEOUT_SECS)
    raise ArgumentError, "endpoint_url is missing" if endpoint_url.blank?
    raise ArgumentError, "trigger bearer token is missing" if trigger_bearer_token.blank?

    uri = URI("#{endpoint_url.to_s.delete_suffix('/')}/trigger")
    http_request = Net::HTTP::Post.new(uri)
    http_request["Authorization"] = "Bearer #{trigger_bearer_token}"
    http_request["Content-Type"] = "application/json"
    body = {
      trigger_kind: trigger_kind,
      conversation_id: conversation_id,
      requested_by: requested_by,
      session_id: session_id,
      request: request
    }
    body.merge!(trigger_payload.to_h.symbolize_keys.except(*body.keys))
    body[:provider] = provider if provider.present?
    body[:model] = model if model.present?
    body[:reasoning_effort] = reasoning_effort if reasoning_effort.present? && reasoning_effort != "default"
    body[:auth_mode] = auth_mode if auth_mode.present?
    body[:timeout_secs] = runtime_timeout_secs if runtime_timeout_secs.present?
    body[:request_delta] = request_delta if request_delta.present?
    body[:persistent_session] = true if persistent_session
    body[:activity] = activity if activity
    http_request.body = body.to_json

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: read_timeout) do |http|
      http.request(http_request)
    end

    {
      status: response.code.to_i,
      body: parse_body(response.body)
    }
  end

  private

  attr_reader :endpoint_url, :trigger_bearer_token

  def parse_body(body)
    JSON.parse(body)
  rescue JSON::ParserError
    { "raw" => body.to_s }
  end

end
