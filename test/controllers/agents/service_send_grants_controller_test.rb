require "test_helper"
require "support/comms_send_helpers"
require "support/api_human_key_helpers"

# The send grant through the web and the person API (WhatsApp spec §5), the
# gate on both, and the owner-only list of sends and grant history.
class Agents::ServiceSendGrantsControllerTest < ActionDispatch::IntegrationTest

  include CommsSendHelpers
  include ApiHumanKeyHelpers

  setup do
    setup_comms_send
    Setting.instance.update!(allow_agents: true)
  end

  teardown { teardown_comms_send }

  test "the owner grants and withdraws on the web, and both are audited and recorded" do
    sign_in @owner
    patch_grant(true)
    assert @access.reload.can_send?
    assert_equal "Comms Sender can now send as you", flash[:notice]

    patch_grant(false)
    assert_not @access.reload.can_send?
    assert_equal %w[grant_resident_comms_send withdraw_resident_comms_send],
                 AuditLog.where(auditable: @connection).order(:id).pluck(:action).grep(/comms_send/)
    assert_equal [ [ "granted", @owner.id, @agent.id ], [ "withdrawn", @owner.id, @agent.id ] ],
                 @connection.comms_send_grant_events.order(:id).pluck(:action, :actor_user_id, :agent_id)
  end

  test "with sending unavailable, the grant endpoints are 404 and nothing changes" do
    sign_in @owner
    without_sending do
      patch_grant(true, format: :json)
      assert_response :not_found
      patch service_send_grant_api_v1_resident_path(@agent, connection_id: @connection.public_id),
            params: { can_send: true }, as: :json, headers: human_headers(@owner, @account)
      assert_response :not_found
    end
    assert_not @access.reload.can_send?
    assert_equal 0, @connection.comms_send_grant_events.count
  end

  test "a non-owner account admin cannot grant, even when freely provisionable, but can withdraw" do
    @connection.update!(freely_provisionable: true)
    sign_in @account_admin

    patch_grant(true, format: :json)
    assert_response :forbidden
    assert_not @access.reload.can_send?
    assert_equal 0, @connection.comms_send_grant_events.count

    grant_send!
    patch_grant(false, format: :json)
    assert_response :ok
    assert_not @access.reload.can_send?
  end

  test "granting needs the resident's read access first" do
    @access.destroy!
    sign_in @owner
    patch_grant(true, format: :json)
    assert_response :conflict
    assert_nil @agent.agent_service_accesses.find_by(service_connection: @connection)
  end

  test "a send grant change on another account's resident is not found" do
    foreign = agents(:research_assistant)
    sign_in @owner
    patch account_agent_service_access_send_grant_path(@account, foreign, @connection.public_id, format: :json), params: { can_send: true }
    assert_response :not_found
  end

  test "the integrations page shows the send toggle and the sends link to the owner, only while sending is on" do
    grant_send!
    sign_in @owner
    get account_integrations_path(@account)
    connection = inertia_connection
    assert connection["can_grant_send"]
    assert connection["comms_sends_url"]
    resident = connection["residents"].find { |entry| entry["id"] == @agent.to_param }
    assert resident["can_send"]
    assert resident["send_grant_url"]

    without_sending do
      get account_integrations_path(@account)
      connection = inertia_connection
      assert_not connection.key?("can_grant_send")
      resident = connection["residents"].find { |entry| entry["id"] == @agent.to_param }
      assert_not resident.key?("send_grant_url")
      assert_not resident.key?("can_send")
      assert connection["comms_sends_url"], "the history stays readable once there is history"
    end
  end

  test "with sending unavailable, the integrations page offers no sending" do
    without_sending do
      sign_in @owner
      get account_integrations_path(@account)
      connection = inertia_connection
      assert_empty connection.keys & %w[can_grant_send comms_sends_url]
      connection["residents"].each { |resident| assert_empty resident.keys & %w[can_send send_grant_url] }
    end
  end

  test "the person API: only the owner grants, a manager withdraws" do
    @connection.update!(freely_provisionable: true)
    url = service_send_grant_api_v1_resident_path(@agent, connection_id: @connection.public_id)

    patch url, params: { can_send: true }, as: :json, headers: human_headers(@account_admin, @account)
    assert_response :forbidden
    assert_not @access.reload.can_send?

    patch url, params: { can_send: true }, as: :json, headers: human_headers(@owner, @account)
    assert_response :ok
    assert response.parsed_body.dig("service_connection", "can_send")

    patch url, params: { can_send: false }, as: :json, headers: human_headers(@account_admin, @account)
    assert_response :ok
    assert_not @access.reload.can_send?
  end

  test "a resident's own key cannot grant itself send" do
    url = service_send_grant_api_v1_resident_path(@agent, connection_id: @connection.public_id)
    patch url, params: { can_send: true }, as: :json, headers: resident_headers(@owner, @agent)
    assert_response :forbidden
    assert_not @access.reload.can_send?
  end

  test "the person API's read toggle never restores send" do
    grant_send!
    url = service_access_api_v1_resident_path(@agent, connection_id: @connection.public_id)
    patch url, params: { enabled: false }, as: :json, headers: human_headers(@owner, @account)
    patch url, params: { enabled: true }, as: :json, headers: human_headers(@owner, @account)
    assert_response :ok
    assert @access.reload.enabled?
    assert_not @access.can_send?
  end

  test "only the owner can read the sends and the grant history" do
    grant_send!
    send = create_send("On my way", "x1", status: "unknown")

    sign_in @owner
    get account_service_connection_comms_sends_path(@account, @connection.public_id)
    assert_response :ok
    assert_equal "no-store", response.headers["Cache-Control"]
    listed = response.parsed_body["sends"].sole
    assert_equal [ send.public_id, @agent.to_param, "Comms Sender", @chat.provider_chat_id, "Alice", "On my way", "unknown" ],
                 listed.values_at("id", "resident_id", "resident_name", "chat", "chat_name", "text", "status")
    assert listed["requested_at"]
    assert_equal [ [ "granted", @owner.id ] ], response.parsed_body["grant_history"].map { |event| event.values_at("action", "actor_user_id") }
    assert_equal [ @agent.to_param ], response.parsed_body["senders"].map { |sender| sender["resident_id"] }

    reset!
    sign_in @account_admin
    get account_service_connection_comms_sends_path(@account, @connection.public_id)
    assert_response :not_found
  end

  test "the sends and the grant history page past 200 by cursor, so the oldest is reachable" do
    count = Accounts::ServiceConnectionSendsController::LIMIT + 1
    now = Time.current
    # insert_all encrypts text through the attribute type, as create would.
    # Half share one timestamp, so the cursor's id tie-break is what keeps
    # the pages from skipping or repeating.
    at = ->(n) { n <= count / 2 ? now - 1.day : now - 1.day + n.seconds }
    CommsSend.insert_all!((1..count).map do |n|
      { service_connection_id: @connection.id, agent_id: @agent.id, comms_chat_id: @chat.id, text: "send #{n}",
        client_request_id: "page-#{n}", status: "sent", requested_at: at.call(n), dispatched_at: at.call(n),
        provider_message_id: "3EB0#{SecureRandom.hex(8).upcase}", connection_generation: 1, created_at: now, updated_at: now }
    end)
    CommsSendGrantEvent.insert_all!((1..count).map do |n|
      { service_connection_id: @connection.id, agent_id: @agent.id, actor_user_id: @owner.id,
        action: n.odd? ? "granted" : "withdrawn", reason: n.odd? ? "granted" : "withdrawn", created_at: at.call(n) }
    end)
    oldest_send = @connection.comms_sends.order(:requested_at, :id).first
    oldest_grant = @connection.comms_send_grant_events.order(:created_at, :id).first

    sign_in @owner
    get account_service_connection_comms_sends_path(@account, @connection.public_id)
    assert_response :ok
    first = response.parsed_body
    assert_equal Accounts::ServiceConnectionSendsController::LIMIT, first["sends"].size
    assert_equal Accounts::ServiceConnectionSendsController::LIMIT, first["grant_history"].size
    assert_not_includes first["sends"].map { |send| send["id"] }, oldest_send.public_id
    assert first["sends_next_cursor"]
    assert first["grant_history_next_cursor"]

    get account_service_connection_comms_sends_path(@account, @connection.public_id,
                                                     sends_before: first["sends_next_cursor"], grants_before: first["grant_history_next_cursor"])
    assert_response :ok
    second = response.parsed_body
    assert_equal [ oldest_send.public_id ], second["sends"].map { |send| send["id"] }
    assert_equal "send 1", second["sends"].sole["text"]
    assert_equal 1, second["grant_history"].size
    assert_equal oldest_grant.created_at.utc.iso8601, second["grant_history"].sole["at"]
    assert_nil second["sends_next_cursor"]
    assert_nil second["grant_history_next_cursor"]

    all_ids = (first["sends"] + second["sends"]).map { |send| send["id"] }
    assert_equal count, all_ids.uniq.size, "nothing repeated or skipped"
  end

  test "a malformed cursor is a bad request" do
    sign_in @owner
    [ "not-a-cursor", "!!!", Base64.urlsafe_encode64("yesterday|1", padding: false), Base64.urlsafe_encode64("2026-10-24T10:00:00Z|x", padding: false) ].each do |cursor|
      get account_service_connection_comms_sends_path(@account, @connection.public_id, sends_before: cursor)
      assert_response :bad_request, cursor
      get account_service_connection_comms_sends_path(@account, @connection.public_id, grants_before: cursor)
      assert_response :bad_request, cursor
    end
  end

  test "residents cannot read the sends list" do
    create_send("On my way", "x2")
    get account_service_connection_comms_sends_path(@account, @connection.public_id), headers: resident_headers(@owner, @agent)
    assert_not_equal 200, response.status
    assert_no_match "On my way", response.body
  end

  private

  def create_send(text, id, status: "sent")
    @connection.comms_sends.create!(agent: @agent, comms_chat: @chat, text: text, client_request_id: id, status: status,
                                    requested_at: Time.current, provider_message_id: "3EB0#{SecureRandom.hex(8).upcase}",
                                    connection_generation: @connection.pairing_attempt)
  end

  def patch_grant(can_send, format: nil)
    path = account_agent_service_access_send_grant_path(@account, @agent, @connection.public_id, format: format)
    patch path, params: { can_send: can_send }
  end

  def inertia_connection
    @inertia_props = nil
    inertia_shared_props["connections"].find { |entry| entry["id"] == @connection.public_id }
  end

end
