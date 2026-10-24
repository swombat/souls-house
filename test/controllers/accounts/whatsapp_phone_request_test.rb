require "test_helper"
require "support/whatsapp_comms_helpers"

# Mira's review of #357: within one pairing attempt the owner can replace
# the number, retry, or submit from another tab. Each phone request gets its
# own non-secret id (never the number), carried by the signed pair_phone
# command and by the code / failure events that answer it. Only the latest
# request's result is accepted, whatever order the connector ran them in,
# and only the request that failed to send is withdrawn.
class Accounts::WhatsappPhoneRequestTest < ActionDispatch::IntegrationTest

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

  test "each phone request gets its own id, which is not the number" do
    first = request_phone!
    second = request_phone!
    assert_match(/\A[0-9a-f]{16}\z/, first.to_s)
    assert_match(/\A[0-9a-f]{16}\z/, second.to_s)
    assert_not_equal first, second
  end

  # Delayed success: the first number's code arrives after the owner has
  # asked again (replacement number, retry, another tab).
  test "a code for a superseded request is refused, and the current request's code is accepted" do
    first = request_phone!
    second = request_phone!
    assert_refused(:stale_phone_code) { receive!(phone_code_event("OLDC-ODE2", Time.current, first)) }
    assert_nil @connection.reload.pairing_phone_code
    assert_equal "requested", @connection.phone_pairing_state["step"]

    receive!(phone_code_event("NEWC-ODE2", Time.current, second))
    assert_equal "NEWCODE2", @connection.reload.pairing_phone_code
  end

  # Delayed failure: the first request's failure must not clear the code
  # the second one got.
  test "a failure for a superseded request is refused and leaves the current code" do
    first = request_phone!
    second = request_phone!
    receive!(phone_code_event("NEWC-ODE2", Time.current, second))
    assert_refused(:stale_phone_code) { receive!(failure_event("rate_limited", first)) }
    @connection.reload
    assert_equal "NEWCODE2", @connection.pairing_phone_code
    assert_equal "code", @connection.phone_pairing_state["step"]
    assert_nil @connection.phone_pairing_state["error"]
  end

  # Reversed execution: the connector ran the second request first, so the
  # first request's code has the later issued_at. Ordering by issue time
  # would take it; correlation refuses it.
  test "a superseded request's code issued later than the current code is still refused" do
    first = request_phone!
    second = request_phone!
    issued = Time.current
    receive!(phone_code_event("NEWC-ODE2", issued, second))
    assert_refused(:stale_phone_code) { receive!(phone_code_event("OLDC-ODE2", issued + 1.second, first)) }
    assert_equal "NEWCODE2", @connection.reload.pairing_phone_code
  end

  test "a code or failure naming no request, or an unknown one, is refused" do
    request_phone!
    assert_refused(:stale_phone_code) { receive!(phone_code_event("ABCD-2345", Time.current, nil)) }
    assert_refused(:stale_phone_code) { receive!(phone_code_event("ABCD-2345", Time.current, "0123456789abcdef")) }
    assert_refused(:stale_phone_code) { receive!(failure_event("failed", nil)) }
    assert_nil @connection.reload.pairing_phone_code
    assert_equal "requested", @connection.phone_pairing_state["step"]
  end

  # The expiry the connector reports names the request whose code expired.
  test "the current request's failure is accepted, and its request stays named for a later expiry" do
    current = request_phone!
    receive!(phone_code_event("ABCD-2345", Time.current, current))
    receive!(failure_event("expired", current))
    @connection.reload
    assert_nil @connection.pairing_phone_code
    assert_equal "expired", @connection.phone_pairing_state["error"]
    assert_equal current, @connection.phone_pairing_state["request"]
  end

  test "the expiry Rails clears itself keeps the request it belonged to" do
    current = request_phone!
    receive!(phone_code_event("ABCD-2345", Time.current, current))
    travel 151.seconds do
      assert @connection.reload.clear_expired_pairing_phone_code!
      assert_equal({ "error" => "expired", "request" => current }, @connection.phone_pairing_state.slice("error", "request"))
    end
  end

  test "pair_phone carries the request id in the signed body" do
    current = request_phone!
    with_whatsapp_connector do |requests, _options|
      CommsConnector.pair_phone(@connection, E164, attempt: 1, request: current, seq: 1)
      assert_equal current, JSON.parse(requests.sole.body)["request_id"]
    end
  end

  test "the controller sends the request id it recorded" do
    sent = []
    sign_in @owner
    CommsConnector.stub(:pair_phone, ->(_connection, _phone, **options) { sent << options; {} }) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: E164, attempt: 1 }, as: :json
    end
    assert_response :accepted
    assert_equal 1, sent.sole[:attempt]
    assert_equal @connection.reload.phone_pairing_state["request"], sent.sole[:request]
    assert_not_nil sent.sole[:request]
  end

  # Mira's schedule: attempt 1's pair_phone is in flight when another tab
  # restarts to attempt 2 and asks for its code; then attempt 1's call fails.
  # Only attempt 1's request is withdrawn: attempt 2's must survive.
  test "a failed send withdraws only its own request, not a newer attempt's" do
    sign_in @owner
    raced = false
    other_tab = lambda do |connection, _phone, **_options|
      unless raced
        raced = true
        tab = ServiceConnection.find(connection.id)
        assert tab.restart_pairing!
        assert tab.reload.request_phone_pairing!(2)
      end
      raise CommsConnector::Error, "comms connector pair_phone failed (500)"
    end
    CommsConnector.stub(:pair_phone, other_tab) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: E164, attempt: 1 }, as: :json
    end
    assert raced
    assert_response :bad_gateway
    @connection.reload
    assert_equal 2, @connection.pairing_attempt
    assert_equal "requested", @connection.phone_pairing_state["step"]
  end

  test "a failed send withdraws only its own request, not a newer one in the same attempt" do
    sign_in @owner
    newer = nil
    other_tab = lambda do |connection, _phone, **_options|
      newer ||= ServiceConnection.find(connection.id).request_phone_pairing!(1)
      raise CommsConnector::Error, "comms connector pair_phone failed (500)"
    end
    CommsConnector.stub(:pair_phone, other_tab) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: E164, attempt: 1 }, as: :json
    end
    assert_response :bad_gateway
    @connection.reload
    assert_equal "requested", @connection.phone_pairing_state["step"]
    assert_equal newer, @connection.phone_pairing_state["request"]
  end

  test "a failed send with nothing newer withdraws its request" do
    sign_in @owner
    CommsConnector.stub(:pair_phone, ->(*, **) { raise CommsConnector::Error, "comms connector pair_phone failed (500)" }) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: E164, attempt: 1 }, as: :json
    end
    assert_response :bad_gateway
    assert_empty @connection.reload.phone_pairing_state
  end

  private

  # The id of the request just recorded (nil before request ids existed).
  def request_phone!(attempt = 1)
    assert @connection.reload.request_phone_pairing!(attempt)
    @connection.reload.phone_pairing_state["request"]
  end

  def receive!(event, attempt: @connection.reload.pairing_attempt)
    CommsEvents.receive!(ServiceConnection.find(@connection.id), { "attempt" => attempt }.merge(event), nonce: SecureRandom.hex(16))
  end

  def phone_code_event(code, issued_at, request)
    { "type" => "pairing.phone_code", "code" => code, "issued_at" => issued_at.utc.iso8601(6),
      "expires_at" => (issued_at + 150.seconds).utc.iso8601(6), "request_id" => request }.compact
  end

  def failure_event(reason, request)
    { "type" => "pairing.phone_code_failed", "reason" => reason, "request_id" => request }.compact
  end

  def assert_refused(code)
    error = assert_raises(CommsEvents::Refused) { yield }
    assert_equal code, error.code
  end

end
