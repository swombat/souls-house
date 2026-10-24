require "test_helper"
require "support/whatsapp_comms_helpers"

# Mira's second review of #357: Rails records request A, then B, under the
# row lock, but sends each pair_phone after releasing it, so the connector
# can receive B's command before A's. Random request ids correlate results
# but cannot say which command is newer. Each request therefore also gets a
# sequence number, assigned under the same lock, increasing per connection
# and never reset (a restart continues it, so a pre-restart command is
# always older than a post-restart one). The connector refuses a command
# whose sequence is not above the newest it has accepted, before cancelling
# anything (409 stale_request); for Rails that only means a newer request
# already reached the connector, so the owner is answered as for any
# accepted request and nothing is withdrawn.
class Accounts::WhatsappPhoneRequestOrderTest < ActionDispatch::IntegrationTest

  include WhatsappCommsHelpers

  E164 = "+447700900123".freeze

  setup do
    @account = accounts(:team)
    @owner = users(:admin)
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @owner)
    @connection = @account.service_connections.create!(
      connected_by_user: @owner, provider: "whatsapp", management_scope: "personal", status: "pairing",
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload]
    )
  end

  test "each request's sequence is above the last, within an attempt and across a restart" do
    first = record!(1)
    second = record!(1)
    assert_kind_of Integer, first
    assert_operator second, :>, first
    assert @connection.reload.restart_pairing!
    after_restart = record!(2)
    assert_operator after_restart, :>, second, "a restart continues the sequence"
  end

  test "pair_phone carries the request's sequence in the signed body, as a JSON integer" do
    record!(1)
    state = @connection.reload.phone_pairing_state
    with_whatsapp_connector do |requests, _options|
      CommsConnector.pair_phone(@connection, E164, attempt: 1, request: state["request"], seq: state["seq"])
      body = JSON.parse(requests.sole.body)
      assert_equal state["seq"], body["request_seq"]
      assert_kind_of Integer, body["request_seq"]
    end
  end

  test "the controller sends the sequence it recorded with the request" do
    sent = []
    sign_in @owner
    CommsConnector.stub(:pair_phone, ->(_connection, _phone, **options) { sent << options; {} }) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: E164, attempt: 1 }, as: :json
    end
    assert_response :accepted
    state = @connection.reload.phone_pairing_state
    assert_not_nil state["seq"]
    assert_equal state["seq"], sent.sole[:seq]
    assert_equal state["request"], sent.sole[:request]
  end

  # Request A is recorded and sent; meanwhile another tab records B, whose
  # command reaches the connector first; A's command is then refused as
  # stale_request. That is not a failure: B is current, and stays so.
  test "a command the connector refuses as an older request is harmless: answered as accepted, nothing withdrawn" do
    sign_in @owner
    newer = nil
    other_tab = -> { newer = ServiceConnection.find(@connection.id).request_phone_pairing!(1) }
    with_connector_reply(409, { error: "stale_request" }, during: other_tab) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: E164, attempt: 1 }, as: :json
    end
    assert_response :accepted
    assert_equal "requested", response.parsed_body.dig("phone", "step")
    @connection.reload
    assert_equal newer, @connection.phone_pairing_state["request"]
    assert_equal "requested", @connection.phone_pairing_state["step"]
  end

  test "any other refusal is still a failure to send" do
    sign_in @owner
    with_connector_reply(409, { error: "stale_attempt" }) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: E164, attempt: 1 }, as: :json
    end
    assert_response :bad_gateway
    assert_empty @connection.reload.phone_pairing_state
  end

  private

  # Records a phone request for the attempt; returns its sequence (nil
  # before sequences existed).
  def record!(attempt)
    assert @connection.reload.request_phone_pairing!(attempt)
    @connection.reload.phone_pairing_state["seq"]
  end

  # The connector answers every command with status and body; during runs
  # first, while the command is in flight (another tab acting meanwhile).
  def with_connector_reply(status, body, during: nil)
    with_whatsapp_connector(stub_http: false) do
      fake = Object.new
      fake.define_singleton_method(:request) do |_request|
        during&.call
        Net::HTTPResponse::CODE_TO_OBJ[status.to_s].new("1.1", status.to_s, "").tap do |response|
          response.instance_variable_set(:@read, true)
          response.instance_variable_set(:@body, body.to_json)
        end
      end
      Net::HTTP.stub(:start, ->(_host, _port, **_options, &block) { block.call(fake) }) { yield }
    end
  end

end
