require "test_helper"

# WhatsApp is an ordinary ServiceConnection with ordinary AgentServiceAccess
# grants. These cover the parts that differ: the connector credential
# strategy, the callback secret, and disconnect sending unpair.
class ServiceConnectionCommsTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @connection = whatsapp_connection
    @secret = @connection.credential_payload_hash.fetch("callback_secret")
  end

  test "the catalog entry is personal, pairing, connector, read-only" do
    definition = Services::Definition.fetch("whatsapp")
    assert_equal %w[personal], definition.management_scopes
    assert_equal "pairing", definition.connection_method
    assert_equal "connector", definition.credential_strategy
    assert_equal %w[read], definition.access_profiles.keys
    assert_match "soulshouse-comms", definition.runtime_notes.join(" ")
    assert_not definition.supports_management_scope?("account_managed")
  end

  test "definitions refuse unknown connection methods and strategies" do
    assert_raises(ArgumentError) { Services::Definition.new(**definition_attributes(connection_method: "magic")) }
    assert_raises(ArgumentError) { Services::Definition.new(**definition_attributes(credential_strategy: "magic")) }
  end

  test "each connection gets its own random callback secret" do
    assert_match(/\A[0-9a-f]{64}\z/, @secret)
    assert_not_equal @secret, whatsapp_connection.credential_payload_hash["callback_secret"]
  end

  test "runtime credentials carry the read endpoints and never the callback secret" do
    credentials = @connection.runtime_credentials(agent: @agent)

    assert_equal %w[chats_endpoint messages_endpoint], credentials.keys.sort
    assert credentials["chats_endpoint"].end_with?("/api/v1/service_connections/#{@connection.public_id}/comms/chats")
    assert_not_includes credentials.to_json, @secret
    assert_not_includes @connection.runtime_entry(agent: @agent).to_json, @secret
  end

  test "the resident service manifest never contains the callback secret" do
    @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    manifest = Agents::ServiceManifest.new(@agent)

    entry = manifest.to_h["services"].find { |service| service["connection_id"] == @connection.public_id }
    assert_equal "connector", entry["credential_strategy"]
    assert_not_includes manifest.to_yaml, @secret
    assert_not_includes manifest.to_yaml, "callback_secret"
  end

  test "disconnecting sends unpair, signed with the connection's secret, then erases it" do
    requests = []
    with_connector_url("http://comms.internal:8080") do
      Net::HTTP.stub(:start, ->(_host, _port, **_options, &block) { block.call(fake_http(requests)) }) do
        @connection.disconnect!
      end
    end

    request = requests.sole
    assert_equal "/connections/#{@connection.public_id}/unpair", request.path
    nonce = CommsSignature.verify!(
      secret: @secret, expected_connection_id: @connection.public_id, method: "POST",
      path: request.path, body: request.body, headers: request
    )
    assert_match CommsSignature::NONCE_FORMAT, nonce
    assert_equal "revoked", @connection.reload.status
    assert_nil @connection.credential_payload
  end

  test "without a connector URL, a command records its intent and sends nothing" do
    with_connector_url(nil) do
      Net::HTTP.stub(:start, ->(*) { flunk "no request expected" }) do
        assert_equal :not_configured, CommsConnector.unpair(@connection)
        assert_equal :not_configured, CommsConnector.start_pairing(@connection)
      end
    end
  end

  test "a disconnected connection with history is kept, revoked, rather than destroyed" do
    @connection.comms_chats.create!(provider_chat_id: "c1@s.whatsapp.net")
    assert @connection.retained_after_disconnect?
    assert_not whatsapp_connection.retained_after_disconnect?
  end

  private

  def whatsapp_connection
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @user)
    @agent.account.service_connections.create!(
      connected_by_user: @user, provider: "whatsapp", management_scope: "personal", status: "connected",
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload]
    )
  end

  def definition_attributes(**overrides)
    {
      key: "probe", name: "Probe", management_scopes: %w[personal], credential_strategy: "static",
      api_origins: [], documentation: [], adapter_class: "Services::WhatsappAdapter"
    }.merge(overrides)
  end

  def with_connector_url(value)
    previous = ENV["COMMS_CONNECTOR_URL"]
    ENV["COMMS_CONNECTOR_URL"] = value
    yield
  ensure
    ENV["COMMS_CONNECTOR_URL"] = previous
  end

  def fake_http(requests)
    Object.new.tap do |http|
      http.define_singleton_method(:request) do |request|
        requests << request
        Net::HTTPOK.new("1.1", "200", "OK").tap { |response| response.instance_variable_set(:@read, true) }
      end
    end
  end

end
