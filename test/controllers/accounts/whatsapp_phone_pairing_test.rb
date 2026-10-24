require "test_helper"
require "support/whatsapp_comms_helpers"
require "stringio"

# WhatsApp's "Link with phone number instead": the owner gives the number of
# the phone WhatsApp is on, the connector asks WhatsApp for an 8-character
# code (whatsmeow PairPhone), and the owner types that code into WhatsApp on
# the phone. For someone on that very phone, who cannot scan a QR on its own
# screen (the Telegram phone sign-in's reason too).
#
# The number is forwarded inside the request and kept nowhere: no column, no
# connector_state, no log line. The code is stored like the QR (encrypted,
# with its issue time and expiry, owner only, cleared once expired by a
# compare-and-clear) and bound to the pairing attempt like every event.
class Accounts::WhatsappPhonePairingTest < ActionDispatch::IntegrationTest

  include WhatsappCommsHelpers

  PHONE = "+44 7700 900123".freeze
  E164 = "+447700900123".freeze

  setup do
    @account = accounts(:team)
    @owner = users(:admin)            # connected the WhatsApp connection
    @account_admin = users(:owner)    # can manage it, but is not its owner
    @member = users(:member)
    attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @owner)
    @connection = @account.service_connections.create!(
      connected_by_user: @owner, provider: "whatsapp", management_scope: "personal", status: "pairing",
      label: attributes[:label], credential_kind: attributes[:credential_kind],
      credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
      credential_payload_hash: attributes[:credential_payload]
    )
  end

  # --- the owner submits the number -------------------------------------

  test "the owner's number goes to the connector as E.164 with the attempt, and is kept nowhere" do
    sent = []
    sign_in @owner
    log = capture_request_log do
      CommsConnector.stub(:pair_phone, ->(connection, phone, attempt:, request:, seq:) { sent << [ connection.id, phone, attempt, request, seq ]; {} }) do
        post phone_account_service_connection_pairing_path(@account, @connection.public_id),
             params: { phone: PHONE, attempt: 1 }, as: :json
      end
    end

    assert_response :accepted
    assert_equal "no-store", response.headers["Cache-Control"]
    @connection.reload
    assert_equal [ [ @connection.id, E164, 1, @connection.phone_pairing_state["request"], @connection.phone_pairing_state["seq"] ] ], sent
    assert_equal "requested", response.parsed_body.dig("phone", "step")
    assert_equal "requested", @connection.phone_pairing_state["step"]
    row = ServiceConnection.connection.select_all("SELECT * FROM service_connections WHERE id = #{@connection.id}").to_a.to_json
    assert_not_includes row, "7700900123"
    assert_not_includes @connection.credential_payload.to_s, "7700900123"
    assert AuditLog.exists?(action: "request_service_phone_pairing", auditable: @connection)
    assert_not_includes AuditLog.where(auditable: @connection).to_a.to_json, "7700900123"
    assert_includes log, phone_account_service_connection_pairing_path(@account, @connection.public_id), "the request was logged"
    assert_match(/"phone"\s*=>\s*"\[FILTERED\]"/, log, "the request's filtered phone parameter was logged")
    assert_not_includes log, "7700900123"
    assert_not_includes log, "7700 900123"
  end

  test "unrelated log output cannot contaminate the captured pairing request" do
    sign_in @owner
    log = capture_request_log do
      unrelated_write = ->(*) do
        File.open(Rails.root.join("log/test.log"), "a") { |file| file.puts("unrelated WhatsApp SQL: #{PHONE} #{E164}") }
        {}
      end
      CommsConnector.stub(:pair_phone, unrelated_write) do
        post phone_account_service_connection_pairing_path(@account, @connection.public_id),
             params: { phone: PHONE, attempt: 1 }, as: :json
      end
    end

    assert_response :accepted
    assert_includes log, phone_account_service_connection_pairing_path(@account, @connection.public_id), "the request was logged"
    assert_match(/"phone"\s*=>\s*"\[FILTERED\]"/, log, "the request's filtered phone parameter was logged")
    assert_not_includes log, "unrelated WhatsApp SQL"
    assert_not_includes log, "7700900123"
    assert_not_includes log, "7700 900123"
  end

  test "request capture includes secondary framework loggers and detaches after errors" do
    broadcasts = Rails.logger.broadcasts.dup
    log = capture_request_log do
      ActiveJob::Base.logger.info("secondary framework log: #{E164}")
    end
    assert_includes log, "secondary framework log: #{E164}"
    assert_equal broadcasts, Rails.logger.broadcasts

    assert_raises(RuntimeError) { capture_request_log { raise "request failed" } }
    assert_equal broadcasts, Rails.logger.broadcasts
  end

  test "a number that is not E.164 is refused and nothing is sent" do
    sign_in @owner
    [ "", "07700 900123", "447700900123", "+0 7700 900123", "+44 7700", "+44 7700 900123 456789", "+44 7700 abc 123", "+44 (0) 7700 900123" ].each do |phone|
      CommsConnector.stub(:pair_phone, ->(*) { flunk "pair_phone sent for #{phone.inspect}" }) do
        post phone_account_service_connection_pairing_path(@account, @connection.public_id),
             params: { phone:, attempt: 1 }, as: :json
      end
      assert_response :unprocessable_entity, phone.inspect
      assert_match(/\+ and the country code/, response.parsed_body["error"])
    end
    assert_empty @connection.reload.phone_pairing_state
  end

  test "only the owner can ask for a phone code: not an account admin, not another member" do
    [ @account_admin, @member ].each do |user|
      sign_in user
      CommsConnector.stub(:pair_phone, ->(*) { flunk "pair_phone sent for #{user.email_address}" }) do
        post phone_account_service_connection_pairing_path(@account, @connection.public_id),
             params: { phone: PHONE, attempt: 1 }, as: :json
      end
      assert_response :not_found
    end
    assert_empty @connection.reload.phone_pairing_state
  end

  test "a number for an attempt the owner has since restarted is refused" do
    @connection.restart_pairing!
    sign_in @owner
    CommsConnector.stub(:pair_phone, ->(*) { flunk "pair_phone sent for an old attempt" }) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: PHONE, attempt: 1 }, as: :json
    end
    assert_response :conflict
    assert_empty @connection.reload.phone_pairing_state
  end

  test "a linked connection is not asked for a code" do
    @connection.update!(status: "connected")
    sign_in @owner
    CommsConnector.stub(:pair_phone, ->(*) { flunk "pair_phone sent for a linked connection" }) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: PHONE, attempt: 1 }, as: :json
    end
    assert_response :conflict
  end

  test "an unreachable connector is reported, and says nothing of the number" do
    sign_in @owner
    CommsConnector.stub(:pair_phone, ->(*) { raise CommsConnector::Error, "comms connector pair_phone failed (500)" }) do
      post phone_account_service_connection_pairing_path(@account, @connection.public_id),
           params: { phone: PHONE, attempt: 1 }, as: :json
    end
    assert_response :bad_gateway
    assert_match(/Could not reach the WhatsApp connector/, response.parsed_body["error"])
    assert_not_includes response.body, "7700"
  end

  test "a Telegram connection has no WhatsApp phone pairing" do
    @connection.update_columns(provider: "telegram")
    sign_in @owner
    post phone_account_service_connection_pairing_path(@account, @connection.public_id),
         params: { phone: PHONE, attempt: 1 }, as: :json
    assert_response :not_found
  end

  # Found by the browser test: after Restart pairing the page still held
  # attempt 1 until its next poll, so a number sent at once was refused as
  # an old attempt's. The restart's own answer carries the new attempt.
  test "restarting answers with the new attempt, so the next number joins it" do
    sign_in @owner
    CommsConnector.stub(:start_pairing, :sent) do
      post restart_account_service_connection_pairing_path(@account, @connection.public_id)
    end
    assert_response :ok
    assert_equal 2, response.parsed_body["attempt"]
    assert_equal({}, response.parsed_body["phone"])
    assert_nil response.parsed_body["phone_code"]
  end

  test "pair_phone is a signed command carrying the E.164 number and the attempt" do
    with_whatsapp_connector do |requests, options|
      CommsConnector.pair_phone(@connection, E164, attempt: 3, request: "0123456789abcdef", seq: 4)
      request = requests.sole
      assert_equal "/connections/#{@connection.public_id}/pair_phone", request.path
      body = JSON.parse(request.body)
      assert_equal({ "phone_number" => E164, "attempt" => 3, "request_id" => "0123456789abcdef", "request_seq" => 4,
                     "connection" => @connection.public_id, "operation" => "pair_phone" },
                   body.slice("phone_number", "attempt", "request_id", "request_seq", "connection", "operation"))
      expected = CommsCommandSignature.sign(
        secret: "test-command-key", key_id: "k1", connection_id: @connection.public_id, operation: "pair_phone",
        command_id: request["X-Comms-Command-Id"], issued_at: request["X-Comms-Issued-At"], body: request.body
      )
      assert_equal expected, request["X-Comms-Command-Signature"]
      assert_equal [ body["command_id"], body["issued_at"].to_s ], [ request["X-Comms-Command-Id"], request["X-Comms-Issued-At"] ]
      assert options.sole[:use_ssl]
    end
  end

  # --- the code comes back as a signed event --------------------------------

  test "the code is stored for the attempt and shown to the owner only, formatted XXXX-XXXX" do
    request_phone!
    issued = Time.current
    receive!(phone_code_event("ABCD2345", issued, 150.seconds))

    sign_in @owner
    get account_service_connection_pairing_path(@account, @connection.public_id)
    assert_response :ok
    assert_equal "ABCD-2345", response.parsed_body.dig("phone_code", "code")
    assert_equal issued.utc.iso8601(3), response.parsed_body.dig("phone_code", "issued_at")
    assert_equal "code", response.parsed_body.dig("phone", "step")
    assert_equal 1, response.parsed_body["attempt"]

    [ @account_admin, @member ].each do |user|
      sign_in user
      get account_service_connection_pairing_path(@account, @connection.public_id)
      assert_response :not_found
      assert_not_includes response.body, "ABCD"
    end
    assert_not_includes @connection.reload.as_connection_json(current_user: @owner).to_json, "ABCD"
    assert_not_includes ServiceConnection.connection.select_value("SELECT pairing_phone_code FROM service_connections WHERE id = #{@connection.id}").to_s, "ABCD"
  end

  test "a code is refused unless the owner asked for one in this attempt" do
    assert_refused(:stale_phone_code) { receive!(phone_code_event("ABCD2345", Time.current, 150.seconds)) }
    request_phone!
    assert_refused(:stale_attempt) { receive!(phone_code_event("ABCD2345", Time.current, 150.seconds), attempt: 2) }
    assert_nil @connection.reload.pairing_phone_code
  end

  test "malformed, expired, overlong or older codes are refused" do
    request_phone!
    assert_refused(:bad_phone_code) { receive!(phone_code_event("ABC-123", Time.current, 150.seconds)) }
    assert_refused(:bad_phone_code) { receive!(phone_code_event("ABCD 2345<", Time.current, 150.seconds)) }
    assert_refused(:expired_phone_code) { receive!(phone_code_event("ABCD2345", 200.seconds.ago, 150.seconds)) }
    assert_refused(:bad_phone_code) { receive!(phone_code_event("ABCD2345", Time.current, 10.minutes)) }
    newer = Time.current
    receive!(phone_code_event("NEWE-R234", newer, 150.seconds))
    assert_refused(:stale_phone_code) { receive!(phone_code_event("OLDE-R234", newer - 1.second, 150.seconds)) }
    assert_equal "NEWER234", @connection.reload.pairing_phone_code
  end

  test "an expired code is never served and is cleared; a fresh one rotated in meanwhile is kept" do
    request_phone!
    receive!(phone_code_event("OLDC-ODE2", Time.current, 150.seconds))
    sign_in @owner
    travel 151.seconds do
      get account_service_connection_pairing_path(@account, @connection.public_id)
      assert_nil response.parsed_body["phone_code"]
      assert_equal({ "error" => "expired" }, response.parsed_body["phone"])
      assert_nil @connection.reload.pairing_phone_code
    end

    @connection.update!(pairing_phone_code: "EXPIRED2", pairing_phone_code_issued_at: 200.seconds.ago,
                        pairing_phone_code_expires_at: 1.second.ago)
    loaded = ServiceConnection.find(@connection.id)
    rotated = false
    loaded.define_singleton_method(:current_pairing_phone_code) do |**options|
      unless rotated
        rotated = true
        ServiceConnection.find(id).update!(pairing_phone_code: "FRES-HCD2".delete("-"), pairing_phone_code_issued_at: Time.current,
                                           pairing_phone_code_expires_at: 150.seconds.from_now)
      end
      super(**options)
    end
    ServiceConnection.stub(:find_by_public_id!, loaded) do
      get account_service_connection_pairing_path(@account, @connection.public_id)
    end
    assert rotated, "the rotation was injected"
    assert_equal "FRESHCD2", @connection.reload.pairing_phone_code
    assert_equal "FRES-HCD2", response.parsed_body.dig("phone_code", "code")
  end

  test "a failure is shown as its fixed reason and clears the code; an unknown reason is refused" do
    request_phone!
    receive!(phone_code_event("ABCD2345", Time.current, 150.seconds))
    receive!(failure_event("rate_limited"))
    @connection.reload
    assert_nil @connection.pairing_phone_code
    assert_equal "rate_limited", @connection.phone_pairing_state["error"]
    assert_refused(:unknown_phone_code_failure) { receive!(failure_event("447700900123 not found")) }
  end

  test "linking clears the code and the phone step, like the QR" do
    request_phone!
    receive!(phone_code_event("ABCD2345", Time.current, 150.seconds))
    receive!({ "type" => "status.changed", "status" => "connected", "identity" => { "user_id" => "447700900123", "display_name" => "Ada" } })
    @connection.reload
    assert_equal "connected", @connection.status
    assert_nil @connection.pairing_phone_code
    assert_nil @connection.pairing_phone_code_expires_at
    assert_empty @connection.phone_pairing_state
  end

  test "restarting pairing or disconnecting clears the code and the phone step" do
    request_phone!
    receive!(phone_code_event("ABCD2345", Time.current, 150.seconds))
    assert @connection.reload.restart_pairing!
    assert_nil @connection.reload.pairing_phone_code
    assert_empty @connection.phone_pairing_state

    assert @connection.request_phone_pairing!(2)
    receive!(phone_code_event("ABCD2345", Time.current, 150.seconds), attempt: 2)
    CommsConnector.stub(:unpair!, :sent) { @connection.reload.disconnect! }
    assert_nil @connection.reload.pairing_phone_code
  end

  test "QR codes keep arriving while the owner uses the phone code (either one can link)" do
    request_phone!
    receive!(phone_code_event("ABCD2345", Time.current, 150.seconds))
    receive!({ "type" => "pairing.qr", "code" => "2@QR", "issued_at" => Time.current.iso8601(6), "expires_at" => 20.seconds.from_now.iso8601(6) })
    @connection.reload
    assert_equal "2@QR", @connection.pairing_qr
    assert_equal "ABCD2345", @connection.pairing_phone_code
  end

  private

  def capture_request_log
    output = StringIO.new
    capture = ActiveSupport::Logger.new(output)
    logger = Rails.logger

    # Capture every framework logger in this process, not other workers' file writes.
    logger.broadcast_to(capture)
    yield

    output.string
  ensure
    logger.stop_broadcasting_to(capture)
  end

  def request_phone!(attempt = 1)
    assert @connection.reload.request_phone_pairing!(attempt)
  end

  def receive!(event, attempt: @connection.reload.pairing_attempt)
    CommsEvents.receive!(ServiceConnection.find(@connection.id), { "attempt" => attempt }.merge(event), nonce: SecureRandom.hex(16))
  end

  # Naming the connection's current phone request, as the connector does.
  def phone_code_event(code, issued_at, lifetime)
    { "type" => "pairing.phone_code", "code" => code, "issued_at" => issued_at.utc.iso8601(6),
      "expires_at" => (issued_at + lifetime).utc.iso8601(6), "request_id" => current_request }.compact
  end

  def failure_event(reason)
    { "type" => "pairing.phone_code_failed", "reason" => reason, "request_id" => current_request }.compact
  end

  def current_request
    ServiceConnection.find(@connection.id).phone_pairing_state["request"]
  end

  def assert_refused(code)
    error = assert_raises(CommsEvents::Refused) { yield }
    assert_equal code, error.code
  end

end
