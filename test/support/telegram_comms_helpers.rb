# Shared setup for the Telegram comms tests: a connection made the way the
# integrations page makes one, signed connector events, and a fake connector
# that records commands and answers with canned JSON.
module TelegramCommsHelpers

  def telegram_connection(account:, user:, status: "connected", generation: 1)
    attributes = Services::Definition.fetch("telegram").adapter.connection_attributes(credentials: {}, user: user)
    account.service_connections.create!(
      connected_by_user: user, provider: "telegram", management_scope: "personal", status: status,
      login_generation: generation,
      **attributes.slice(:label, :credential_kind, :credential_fingerprint, :credential_metadata)
        .merge(credential_payload_hash: attributes[:credential_payload])
    )
  end

  def telegram_events_path(connection)
    Rails.application.routes.url_helpers.internal_comms_connection_events_path(connection.public_id)
  end

  def post_telegram_event(connection, event)
    body = JSON.generate(event)
    headers = CommsSignature.headers_for(
      secret: connection.credential_payload_hash.fetch("callback_secret"), connection_id: connection.public_id,
      method: "POST", path: telegram_events_path(connection), body: body
    ).merge("Content-Type" => "application/json")
    post telegram_events_path(connection), params: body, headers: headers
  end

  def with_telegram_connector(url: "https://comms.internal:8443", key: "test-command-key", replies: {})
    requests = []
    previous = ENV.to_h.slice("COMMS_CONNECTOR_URL", "COMMS_COMMAND_KEY")
    ENV["COMMS_CONNECTOR_URL"] = url
    ENV["COMMS_COMMAND_KEY"] = key
    fake = Object.new
    fake.define_singleton_method(:request) do |request|
      requests << request
      operation = request.path.split("/").last
      reply = replies.fetch(operation, {})
      raise reply if reply.is_a?(Class) && reply <= Exception

      status, body = reply.is_a?(Array) ? reply : [ 200, reply ]
      klass = Net::HTTPResponse::CODE_TO_OBJ[status.to_s]
      klass.new("1.1", status.to_s, "").tap do |response|
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, JSON.generate(body))
      end
    end
    options_seen = []
    Net::HTTP.stub(:start, ->(_host, _port, **options, &block) { options_seen << options; block.call(fake) }) do
      yield requests, options_seen
    end
  ensure
    %w[COMMS_CONNECTOR_URL COMMS_COMMAND_KEY].each { |name| ENV[name] = previous[name] }
  end

end
