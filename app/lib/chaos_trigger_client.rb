class ChaosTriggerClient

  DEFAULT_RUNTIME_TIMEOUT_SECS = 30.minutes.to_i
  DEFAULT_READ_TIMEOUT_SECS = DEFAULT_RUNTIME_TIMEOUT_SECS + 30

  def initialize(endpoint_url, trigger_bearer_token)
    require "net/http"

    @endpoint_url = endpoint_url
    @trigger_bearer_token = trigger_bearer_token
  end

  def request_response(conversation_id:, requested_by:, session_id:, request:, trigger_kind: "conversation", provider: nil, model: nil, reasoning_effort: nil, auth_mode: nil, request_delta: nil, persistent_session: false, session_policy: nil, trigger_payload: nil, activity: nil, read_timeout: nil, runtime_timeout_secs: DEFAULT_RUNTIME_TIMEOUT_SECS, interaction: nil, completion_context: {})
    raise ArgumentError, "endpoint_url is missing" if endpoint_url.blank?
    raise ArgumentError, "trigger bearer token is missing" if trigger_bearer_token.blank?
    if Agents::RemoteRuntime.remote_endpoint?(endpoint_url) && !ResidentTurn.enabled?
      raise ArgumentError, "a VM resident is reachable only through asynchronous turns"
    end

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
    if persistent_session
      body[:persistent_session] = true
      body[:session_policy] = session_policy if session_policy.present?
    end
    body[:activity] = activity if activity
    if ResidentTurn.enabled?
      raise ArgumentError, "asynchronous turns require an interaction" unless interaction
      turn = ResidentTurn.enqueue!(interaction, body, completion_context: completion_context)
      return { status: 202, body: { "status" => "queued", "dispatch_id" => turn.dispatch_id } }
    end

    # Built only on the synchronous path: a VM resident's endpoint is a
    # runner:// address, which Net::HTTP refuses, and it never gets here.
    uri = URI("#{endpoint_url.to_s.delete_suffix('/')}/trigger")
    http_request = Net::HTTP::Post.new(uri)
    http_request["Authorization"] = "Bearer #{trigger_bearer_token}"
    http_request["Content-Type"] = "application/json"
    http_request.body = body.to_json

    read_timeout ||= (runtime_timeout_secs || DEFAULT_RUNTIME_TIMEOUT_SECS) + 30
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 5, read_timeout: read_timeout) do |http|
      http.request(http_request)
    end

    {
      status: response.code.to_i,
      body: parse_body(response.body)
    }
  rescue ResidentTurn::SessionBusy
    { status: 409, body: { "status" => "already_running" } }
  end

  def submit_turn(id, payload, ledger_id:)
    turn_request(Net::HTTP::Post, id, payload, ledger_id: ledger_id)
  end

  def turn_status(id)
    turn_request(Net::HTTP::Get, id)
  end

  def cancel_turn(id, ledger_id:, payload: nil)
    turn_request(Net::HTTP::Delete, id, payload, ledger_id: ledger_id)
  end

  def resolve_turn(id)
    turn_request(Net::HTTP::Post, id, { execution_stopped: true }, suffix: "/resolve")
  end

  private

  attr_reader :endpoint_url, :trigger_bearer_token

  def turn_request(method, id, payload = nil, suffix: "", ledger_id: nil)
    raise ArgumentError, "invalid dispatch id" unless id.match?(/\A[0-9a-f-]{36}\z/)
    uri = URI("#{endpoint_url.to_s.delete_suffix('/')}/turns/#{id}#{suffix}")
    request = method.new(uri)
    request["Authorization"] = "Bearer #{trigger_bearer_token}"
    request["Content-Type"] = "application/json"
    request["X-Resident-Ledger-ID"] = ledger_id if ledger_id
    request.body = payload.to_json if payload
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", open_timeout: 3, read_timeout: 5) { |http| http.request(request) }
    { status: response.code.to_i, body: parse_body(response.body) }
  end

  def parse_body(body)
    JSON.parse(body)
  rescue JSON::ParserError
    { "raw" => body.to_s }
  end

end
