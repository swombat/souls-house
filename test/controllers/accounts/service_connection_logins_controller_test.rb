require "test_helper"
require "support/telegram_comms_helpers"

# The owner-only Telegram login steps (proposal 2026-10-11 §6.2): restart,
# cancel, and the two-step password, which is forwarded within the request
# and kept nowhere.
class Accounts::ServiceConnectionLoginsControllerTest < ActionDispatch::IntegrationTest

  include TelegramCommsHelpers

  PASSWORD = "canary-Pa55word-7f3c"

  setup do
    @account = accounts(:team)
    @owner = users(:admin)
    @account_admin = users(:owner)
    @member = users(:member)
    @connection = telegram_connection(account: @account, user: @owner, status: "pairing", generation: 4)
    @connection.update!(connector_state: { "login" => { "step" => "password", "hint" => "dog" } })
  end

  test "the owner's password goes to the connector, bound to the current generation, and is stored nowhere" do
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    previous_logger = Rails.logger
    Rails.logger = logger
    ActiveRecord::Base.logger = logger

    sign_in @owner
    with_telegram_connector(replies: { "submit_password" => { outcome: "accepted" } }) do |requests, options|
      assert_no_enqueued_jobs do
        post password_account_service_connection_login_path(@account, @connection.public_id), params: { password: PASSWORD, generation: 4 }, as: :json
      end

      assert_response :ok
      assert_equal({ "outcome" => "accepted" }, response.parsed_body)
      request = requests.sole
      body = JSON.parse(request.body)
      assert_equal "/connections/#{@connection.public_id}/submit_password", request.path
      assert_equal PASSWORD, body["password"]
      assert_equal 4, body["generation"]
      assert_equal "submit_password", body["operation"]
      assert options.sole[:use_ssl]
      assert_equal OpenSSL::SSL::VERIFY_PEER, options.sole[:verify_mode]
    end

    assert_not_includes log.string, PASSWORD
    assert_not_includes @connection.reload.attributes.to_json, PASSWORD
    assert_not_includes @connection.credential_payload.to_s, PASSWORD
    assert_not AuditLog.where("data::text LIKE ?", "%#{PASSWORD}%").exists?
  ensure
    Rails.logger = previous_logger
    ActiveRecord::Base.logger = previous_logger
  end

  test "a wrong password is reported, and the connector's error never echoes the password" do
    sign_in @owner
    with_telegram_connector(replies: { "submit_password" => { outcome: "password_invalid" } }) do
      post password_account_service_connection_login_path(@account, @connection.public_id), params: { password: PASSWORD, generation: 4 }, as: :json
    end
    assert_equal({ "outcome" => "password_invalid" }, response.parsed_body)

    with_telegram_connector(replies: { "submit_password" => [ 500, { error: PASSWORD } ] }) do
      post password_account_service_connection_login_path(@account, @connection.public_id), params: { password: PASSWORD, generation: 4 }, as: :json
    end
    assert_response :bad_gateway
    assert_not_includes response.body, PASSWORD
  end

  test "nobody but the owner can submit a password or restart" do
    [ @account_admin, @member ].each do |user|
      sign_in user
      with_telegram_connector do |requests|
        post password_account_service_connection_login_path(@account, @connection.public_id), params: { password: PASSWORD, generation: 4 }, as: :json
        assert_response :not_found
        post restart_account_service_connection_login_path(@account, @connection.public_id), as: :json
        assert_response :not_found
        assert_empty requests
      end
    end
  end

  test "a password for an attempt that has moved on is refused and not sent" do
    sign_in @owner
    with_telegram_connector do |requests|
      post password_account_service_connection_login_path(@account, @connection.public_id), params: { password: PASSWORD, generation: 3 }, as: :json
      assert_response :conflict
      post password_account_service_connection_login_path(@account, @connection.public_id), params: { password: PASSWORD }, as: :json
      assert_response :unprocessable_entity
      assert_empty requests
    end
  end

  test "restart and cancel are refused for a connected connection" do
    @connection.update!(status: "connected", connector_state: {})
    sign_in @owner
    with_telegram_connector do |requests|
      post restart_account_service_connection_login_path(@account, @connection.public_id), as: :json
      assert_response :conflict
      post cancel_account_service_connection_login_path(@account, @connection.public_id), as: :json
      assert_response :conflict
      assert_empty requests
      assert_equal 4, @connection.reload.login_generation
    end
  end

  test "a password is refused when none is being asked for" do
    @connection.update!(connector_state: {})
    sign_in @owner
    with_telegram_connector do |requests|
      post password_account_service_connection_login_path(@account, @connection.public_id), params: { password: PASSWORD, generation: 4 }, as: :json
      assert_response :conflict
      assert_empty requests
    end
  end

  test "restart moves to a new generation and asks for a fresh QR; cancel moves on again" do
    sign_in @owner
    with_telegram_connector do |requests|
      post restart_account_service_connection_login_path(@account, @connection.public_id), as: :json
      assert_response :ok
      start = JSON.parse(requests.last.body)
      assert_equal "start_login", start["operation"]
      assert_equal 5, start["generation"]
      assert_equal 5, @connection.reload.login_generation
      assert_equal({}, @connection.login_state)

      post cancel_account_service_connection_login_path(@account, @connection.public_id), as: :json
      cancel = JSON.parse(requests.last.body)
      assert_equal "cancel_login", cancel["operation"]
      assert_equal 5, cancel["generation"]
      assert_equal 6, @connection.reload.login_generation
      assert_equal "cancelled", @connection.login_state["error"]
    end
  end

  test "a reauthorizing connection signs in again through restart" do
    @connection.update!(status: "reauthorizing")
    sign_in @owner
    with_telegram_connector do |requests|
      post restart_account_service_connection_login_path(@account, @connection.public_id), as: :json
      assert_response :ok
      assert_equal "pairing", @connection.reload.status
      assert_equal "start_login", JSON.parse(requests.sole.body)["operation"]
    end
  end

  test "the pairing endpoint shows the owner the login step" do
    sign_in @owner
    get account_service_connection_pairing_path(@account, @connection.public_id)
    assert_equal({ "step" => "password", "hint" => "dog" }, response.parsed_body["login"])
    assert_equal 4, response.parsed_body["generation"]
  end

  # -- the phone number and code (signing in on the phone itself) --------------

  PHONE = "+44 7700 900 123"
  PHONE_DIGITS = "7700900123"
  CODE = "8642097531"

  test "the owner's phone number goes to the connector for the current attempt, and the code step is recorded without it" do
    @connection.update!(connector_state: {}, pairing_qr: "tg://login?token=x", pairing_qr_expires_at: 1.minute.from_now,
                        pairing_qr_issued_at: Time.current)
    log = capture_logs do
      sign_in @owner
      reply = { outcome: "code_sent", delivery: "app", length: 5, next_delivery: "sms", timeout: 60 }
      with_telegram_connector(replies: { "request_code" => reply }) do |requests, options|
        assert_no_enqueued_jobs do
          post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 4 }, as: :json
        end
        assert_response :ok
        assert_equal({ "outcome" => "code_sent", "generation" => 4,
                       "login" => { "step" => "code", "delivery" => "app", "length" => 5, "next_delivery" => "sms", "timeout" => 60 } },
                     response.parsed_body)
        body = JSON.parse(requests.sole.body)
        assert_equal "/connections/#{@connection.public_id}/request_code", requests.sole.path
        assert_equal [ PHONE, 4, "request_code" ], body.values_at("phone", "generation", "operation")
        assert options.sole[:use_ssl]
      end
    end

    @connection.reload
    assert_equal "code", @connection.login_state["step"]
    assert_nil @connection.pairing_qr
    assert_no_secret_kept log, PHONE_DIGITS, "7700 900 123"
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "the code goes to the connector for the attempt that asked, and is kept nowhere" do
    @connection.update!(connector_state: { "login" => { "step" => "code", "delivery" => "app" } })
    log = capture_logs do
      sign_in @owner
      with_telegram_connector(replies: { "submit_code" => { outcome: "password_required" } }) do |requests|
        post code_account_service_connection_login_path(@account, @connection.public_id), params: { code: " #{CODE} ", generation: 4 }, as: :json
        assert_response :ok
        assert_equal({ "outcome" => "password_required" }, response.parsed_body)
        body = JSON.parse(requests.sole.body)
        assert_equal [ CODE, 4, "submit_code" ], body.values_at("code", "generation", "operation")
      end
    end
    assert_no_secret_kept log, CODE
  end

  test "outcomes are passed through only from the known list, and a connector error never echoes the number" do
    @connection.update!(connector_state: {})
    sign_in @owner
    with_telegram_connector(replies: { "request_code" => { outcome: "flood_wait", retry_after: 30 } }) do
      post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 4 }, as: :json
    end
    assert_equal({ "outcome" => "flood_wait", "retry_after" => 30, "generation" => 4 }, response.parsed_body)
    with_telegram_connector(replies: { "request_code" => { outcome: "something new", detail: PHONE } }) do
      post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 4 }, as: :json
    end
    assert_equal({ "outcome" => "failed", "generation" => 4 }, response.parsed_body)
    with_telegram_connector(replies: { "request_code" => [ 500, { error: PHONE } ] }) do
      post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 4 }, as: :json
    end
    assert_response :bad_gateway
    assert_not_includes response.body, PHONE_DIGITS
    assert_equal({}, @connection.reload.login_state, "only code_sent records a step")
  end

  test "a number or code for an attempt that has moved on, or out of step, is refused and not sent" do
    sign_in @owner
    with_telegram_connector do |requests|
      # A password is being asked for: no code path now.
      post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 4 }, as: :json
      assert_response :conflict
      post code_account_service_connection_login_path(@account, @connection.public_id), params: { code: CODE, generation: 4 }, as: :json
      assert_response :conflict

      @connection.update!(connector_state: { "login" => { "step" => "code", "delivery" => "app" } })
      post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 3 }, as: :json
      assert_response :conflict
      post code_account_service_connection_login_path(@account, @connection.public_id), params: { code: CODE, generation: 3 }, as: :json
      assert_response :conflict
      post code_account_service_connection_login_path(@account, @connection.public_id), params: { code: CODE }, as: :json
      assert_response :unprocessable_entity
      post code_account_service_connection_login_path(@account, @connection.public_id), params: { code: " ", generation: 4 }, as: :json
      assert_response :unprocessable_entity
      post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: "", generation: 4 }, as: :json
      assert_response :unprocessable_entity

      # Cancelled: the attempt is over.
      @connection.update!(login_generation: 5, connector_state: { "login" => { "error" => "cancelled" } })
      post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 5 }, as: :json
      assert_response :conflict
      assert_empty requests
    end
  end

  test "nobody but the owner can send a number or a code, or open the sign-in page" do
    @connection.update!(connector_state: { "login" => { "step" => "code", "delivery" => "app" } })
    [ @account_admin, @member ].each do |user|
      sign_in user
      with_telegram_connector do |requests|
        post phone_account_service_connection_login_path(@account, @connection.public_id), params: { phone: PHONE, generation: 4 }, as: :json
        assert_response :not_found
        post code_account_service_connection_login_path(@account, @connection.public_id), params: { code: CODE, generation: 4 }, as: :json
        assert_response :not_found
        get account_service_connection_login_path(@account, @connection.public_id)
        assert_response :not_found
        assert_empty requests
      end
    end
  end

  test "the focused sign-in page shows the owner this connection" do
    sign_in @owner
    get account_service_connection_login_path(@account, @connection.public_id)
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    page = inertia_page
    assert_equal "accounts/telegram_sign_in", page["component"]
    assert_equal @connection.public_id, page.dig("props", "connection", "id")
    assert_equal "pairing", page.dig("props", "connection", "status")
    assert_equal account_integrations_path(@account), page.dig("props", "integrations_url")
  end

  test "Connect Telegram opens the focused sign-in page" do
    sign_in @owner
    with_telegram_connector do |requests|
      post account_service_connections_path(@account), params: { provider: "telegram", management_scope: "personal" }
      connection = @account.service_connections.where(provider: "telegram").order(:id).last
      assert_redirected_to account_service_connection_login_path(@account, connection.public_id)
      assert_equal "start_login", JSON.parse(requests.sole.body)["operation"]
    end
  end

  private

  def capture_logs
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    previous_logger = Rails.logger
    Rails.logger = logger
    ActiveRecord::Base.logger = logger
    yield
    log.string
  ensure
    Rails.logger = previous_logger
    ActiveRecord::Base.logger = previous_logger
  end

  def assert_no_secret_kept(log, *secrets)
    secrets.each do |secret|
      assert_not_includes log, secret, "in the log"
      assert_not_includes @connection.reload.attributes.to_json, secret
      assert_not_includes @connection.credential_payload.to_s, secret
      assert_not AuditLog.where("data::text LIKE ?", "%#{secret}%").exists?
    end
  end

  def inertia_page
    JSON.parse(Nokogiri::HTML(response.body).at_css("[data-page]")&.[]("data-page") || response.body)
  end

end
