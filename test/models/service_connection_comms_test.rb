require "test_helper"
require "support/whatsapp_comms_helpers"

# WhatsApp is an ordinary ServiceConnection with ordinary AgentServiceAccess
# grants. These cover the parts that differ: the connector credential
# strategy, the callback secret, and disconnect sending unpair.
class ServiceConnectionCommsTest < ActiveSupport::TestCase

  include WhatsappCommsHelpers

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

  # The connector cannot hold a connection's callback secret before it is
  # handed over, so commands are signed with the connector-wide command key
  # (the Telegram path, proposal 2026-10-11 §5) and travel over mutual TLS.
  test "disconnecting sends unpair, signed with the command key over mutual TLS, then erases the secret" do
    with_whatsapp_connector do |requests, options|
      @connection.disconnect!

      request = requests.sole
      assert_equal "/connections/#{@connection.public_id}/unpair", request.path
      body = JSON.parse(request.body)
      assert_equal [ @connection.public_id, "unpair" ], body.values_at("connection", "operation")
      assert_not_includes request.body, @secret
      expected = CommsCommandSignature.sign(
        secret: "test-command-key", key_id: "k1", connection_id: @connection.public_id, operation: "unpair",
        command_id: body["command_id"], issued_at: body["issued_at"], body: request.body
      )
      assert_equal expected, request["X-Comms-Command-Signature"]
      assert_equal OpenSSL::SSL::VERIFY_PEER, options.sole[:verify_mode]
      assert_equal "/CN=rails", options.sole[:cert].subject.to_s
    end
    assert_equal "revoked", @connection.reload.status
    assert_nil @connection.credential_payload
  end

  test "start_pairing hands the connector the callback secret and its version, signed with the command key" do
    with_whatsapp_connector do |requests, _options|
      CommsConnector.start_pairing(@connection)

      request = requests.sole
      assert_equal "/connections/#{@connection.public_id}/start_pairing", request.path
      body = JSON.parse(request.body)
      assert_equal [ "start_pairing", @secret, 1 ], body.values_at("operation", "callback_secret", "callback_secret_version")
      expected = CommsCommandSignature.sign(
        secret: "test-command-key", key_id: "k1", connection_id: @connection.public_id, operation: "start_pairing",
        command_id: body["command_id"], issued_at: body["issued_at"], body: request.body
      )
      assert_equal expected, request["X-Comms-Command-Signature"]
    end
  end

  test "WhatsApp commands go to the WhatsApp connector, never over plain http or without the key" do
    with_whatsapp_connector(url: "http://souls-house-comms-whatsapp:8080") do |requests, _options|
      assert_raises(CommsConnector::Error) { CommsConnector.start_pairing(@connection) }
      assert_empty requests
    end
    with_whatsapp_connector(key: nil) do |requests, _options|
      assert_raises(CommsConnector::Error) { CommsConnector.unpair(@connection) }
      assert_empty requests
    end
    with_whatsapp_connector(tls: []) do |requests, _options|
      assert_raises(CommsConnector::Error) { CommsConnector.start_pairing(@connection) }
      assert_empty requests
    end
  end

  test "a refused command is an error, and the adapter turns it into one the owner can read" do
    with_whatsapp_connector(status: 401) do |_requests, _options|
      assert_raises(CommsConnector::Error) { CommsConnector.start_pairing(@connection) }
      assert_raises(Services::WhatsappAdapter::Error) { @connection.definition.adapter.start_pairing(@connection) }
    end
  end

  test "without a connector URL, a command records its intent and sends nothing" do
    with_whatsapp_connector(url: nil) do |requests, _options|
      assert_equal :not_configured, CommsConnector.unpair(@connection)
      assert_equal :not_configured, CommsConnector.start_pairing(@connection)
      assert_empty requests
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

end
