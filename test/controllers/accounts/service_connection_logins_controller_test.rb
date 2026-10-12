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

end
