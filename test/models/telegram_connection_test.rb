require "test_helper"
require "support/telegram_comms_helpers"

# The Telegram connection's catalog entry, its credentials for residents and
# the connector commands (proposal 2026-10-11 §5, §9).
class TelegramConnectionTest < ActiveSupport::TestCase

  include TelegramCommsHelpers

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @connection = telegram_connection(account: @agent.account, user: @user)
    @secret = @connection.credential_payload_hash.fetch("callback_secret")
  end

  test "the catalog entry is personal, pairing, connector, read-only" do
    definition = Services::Definition.fetch("telegram")
    assert_equal %w[personal], definition.management_scopes
    assert_equal "pairing", definition.connection_method
    assert_equal "connector", definition.credential_strategy
    assert_equal %w[read], definition.access_profiles.keys
    assert_match "soulshouse-comms search", definition.runtime_notes.join(" ")
  end

  test "residents get read and search endpoints, never the callback secret" do
    credentials = @connection.runtime_credentials(agent: @agent)
    assert_equal %w[chats_endpoint messages_endpoint search_endpoint], credentials.keys.sort
    assert credentials["search_endpoint"].end_with?("/api/v1/service_connections/#{@connection.public_id}/comms/search")

    @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    manifest = Agents::ServiceManifest.new(@agent).to_h.to_yaml
    assert_not_includes manifest, @secret
    assert_not_includes manifest, "callback_secret"
  end

  test "commands are signed with the command key over connection, operation, id, time and body" do
    request = nil
    with_telegram_connector do |requests|
      CommsConnector.telegram_command(@connection, "logout")
      request = requests.sole
    end

    body = request.body
    parsed = JSON.parse(body)
    assert_equal [ @connection.public_id, "logout" ], parsed.values_at("connection", "operation")
    expected = CommsCommandSignature.sign(
      secret: "test-command-key", key_id: "k1", connection_id: @connection.public_id, operation: "logout",
      command_id: parsed["command_id"], issued_at: parsed["issued_at"], body: body
    )
    assert_equal expected, request["X-Comms-Command-Signature"]
    assert_equal parsed["command_id"], request["X-Comms-Command-Id"]
    assert_match(/\A[0-9a-f]{32}\z/, parsed["command_id"])
  end

  test "each command carries a fresh command id" do
    ids = []
    with_telegram_connector do |requests|
      2.times { CommsConnector.telegram_command(@connection, "logout") }
      ids = requests.map { |request| JSON.parse(request.body)["command_id"] }
    end
    assert_equal 2, ids.uniq.size
  end

  test "start_login hands over the callback secret with its version, under a new generation" do
    pairing = telegram_connection(account: @agent.account, user: @user, status: "pairing", generation: 0)
    with_telegram_connector do |requests|
      pairing.definition.adapter.start_pairing(pairing)
      body = JSON.parse(requests.sole.body)
      assert_equal [ "start_login", 1, 1 ], body.values_at("operation", "generation", "callback_secret_version")
      assert_equal pairing.credential_payload_hash["callback_secret"], body["callback_secret"]
    end
  end

  test "without the command key or over plain http, nothing is sent" do
    with_telegram_connector(key: nil) do |requests|
      assert_raises(CommsConnector::Error) { CommsConnector.telegram_command(@connection, "logout") }
      assert_empty requests
    end
    with_telegram_connector(url: "http://comms.internal") do |requests|
      assert_raises(CommsConnector::Error) { CommsConnector.telegram_command(@connection, "logout") }
      assert_empty requests
    end
  end

  test "without a connector URL a command records its intent and sends nothing" do
    with_telegram_connector(url: nil) do |requests|
      assert_equal :not_configured, CommsConnector.telegram_command(@connection, "logout")
      assert_empty requests
    end
  end

  test "disconnecting logs out at Telegram and erases the secret" do
    with_telegram_connector do |requests|
      @connection.disconnect!
      assert_equal "logout", JSON.parse(requests.sole.body)["operation"]
    end
    assert_equal "revoked", @connection.reload.status
    assert_nil @connection.credential_payload
  end

end
