require "test_helper"
require "support/comms_send_helpers"

# The send grant (WhatsApp spec §5): only the owner grants, managers
# withdraw, defaults never grant, and nothing revives a grant once the access
# row or the connection's authority changes. Every change is recorded.
class CommsSendGrantTest < ActiveSupport::TestCase

  include CommsSendHelpers

  setup { setup_comms_send }
  teardown { teardown_comms_send }

  test "read never implies send: a new access row cannot send" do
    assert @access.enabled?
    assert_not @access.can_send?
    assert_not AgentServiceAccess.new.can_send?
  end

  test "only the owner can grant; a non-owner admin cannot, even on a freely provisionable connection" do
    @connection.update!(freely_provisionable: true)
    assert @connection.provisionable_by?(@account_admin), "the admin can grant read here"

    assert_not @connection.send_grant_changeable_by?(@account_admin, can_send: true)
    assert_raises(AgentServiceAccess::SendGrantRefused) { @access.change_send_grant!(true, actor: @account_admin) }
    assert_not @access.reload.can_send?
    assert_equal 0, @connection.comms_send_grant_events.count

    @access.change_send_grant!(true, actor: @owner)
    assert @access.reload.can_send?
  end

  test "no write outside change_send_grant! can set can_send, whoever makes it" do
    assert_not @access.update(can_send: true)
    assert_includes @access.errors[:can_send], "can only be granted by the connection's owner"
    assert_not @access.reload.can_send?
    assert_raises(ActiveRecord::RecordInvalid) do
      @agent.agent_service_accesses.create!(service_connection: build_whatsapp_connection(@account, @owner), enabled: true, can_send: true)
    end
  end

  test "a resident setting its own access (resident-connected services) never gains send" do
    @agent.set_service_access!(@connection, enabled: true, actor: @owner)
    assert @access.reload.enabled?
    assert_not @access.can_send?
  end

  test "a read grant without an authorised person is refused" do
    assert_raises(AgentServiceAccess::ReadGrantRefused) do
      @agent.set_service_access!(@connection, enabled: true, actor: nil)
    end
  end

  test "sending must be available for the provider before anyone can grant" do
    without_sending do
      error = assert_raises(AgentServiceAccess::SendGrantRefused) { @access.change_send_grant!(true, actor: @owner) }
      assert_match "not available", error.message
    end
    assert_not @access.reload.can_send?
    assert_equal 0, @connection.comms_send_grant_events.count
  end

  test "WhatsApp sending is on with no house switch; a provider without a dispatcher stays off (Telegram has none yet)" do
    assert_equal %w[whatsapp], CommsSending.enabled_providers
    assert CommsSending.available_for?(@connection)
  end

  test "a non-owner admin can withdraw the grant, and it is recorded" do
    grant_send!
    assert @connection.send_grant_changeable_by?(@account_admin, can_send: false)

    @access.change_send_grant!(false, actor: @account_admin)

    assert_not @access.reload.can_send?
    events = @connection.comms_send_grant_events.order(:id)
    assert_equal [ %w[granted granted], %w[withdrawn withdrawn] ], events.map { |event| [ event.action, event.reason ] }
    assert_equal [ @owner.id, @account_admin.id ], events.map(&:actor_user_id)
    assert_equal [ @agent.id ], events.map(&:agent_id).uniq
  end

  test "a member who cannot manage the connection cannot withdraw" do
    grant_send!
    stranger = users(:regular_user)
    assert_not @connection.send_grant_changeable_by?(stranger, can_send: false)
    assert_raises(AgentServiceAccess::SendGrantRefused) { @access.change_send_grant!(false, actor: stranger) }
    assert @access.reload.can_send?
  end

  test "the grant needs enabled access and a connected comms connection" do
    @access.update!(enabled: false)
    assert_raises(AgentServiceAccess::SendGrantRefused) { @access.change_send_grant!(true, actor: @owner) }

    @access.update!(enabled: true)
    @connection.update!(status: "pairing")
    assert_raises(AgentServiceAccess::SendGrantRefused) { @access.reload.change_send_grant!(true, actor: @owner) }
    assert_not @access.reload.can_send?
  end

  test "can_send is only valid on a comms access row" do
    dropbox = @account.service_connections.create!(
      connected_by_user: @owner, provider: "dropbox", external_subject_id: "dbid:grant-test", management_scope: "personal",
      credential_kind: "oauth2", credential_payload_hash: { "access_token" => "t" },
      credential_metadata: { "granted_scopes" => Services::Catalog::DROPBOX_READ, "credential_strategy" => "self_refreshing" }
    )
    access = @agent.agent_service_accesses.create!(service_connection: dropbox, enabled: true)
    assert_raises(AgentServiceAccess::SendGrantRefused) { access.change_send_grant!(true, actor: @owner) }
    assert_not access.reload.can_send?
  end

  test "default accesses never carry can_send, for a new connection or a new resident" do
    connection = build_whatsapp_connection(@account, @owner)
    connection.update!(enabled_for_new_agents: true)
    connection.send(:apply_default_accesses)
    assert connection.agent_service_accesses.any?
    assert connection.agent_service_accesses.none?(&:can_send?)

    newcomer = @account.agents.create!(name: "Newcomer", model_id: "openrouter/auto")
    access = newcomer.agent_service_accesses.find_by!(service_connection: connection)
    assert access.enabled?
    assert access.follows_default?
    assert_not access.can_send?
  end

  test "disable then re-enable leaves can_send off (no revival through set_service_access!)" do
    grant_send!

    @agent.set_service_access!(@connection, enabled: false, actor: @account_admin)
    assert_not @access.reload.can_send?
    @agent.set_service_access!(@connection, enabled: true, actor: @owner)

    assert @access.reload.enabled?
    assert_not @access.can_send?
    withdrawal = @connection.comms_send_grant_events.order(:id).last
    assert_equal [ "withdrawn", "access_disabled", @account_admin.id ], [ withdrawal.action, withdrawal.reason, withdrawal.actor_user_id ]
  end

  test "disabling the row any other way also clears can_send" do
    grant_send!
    @access.update!(enabled: false)
    assert_not @access.reload.can_send?
    @access.update!(enabled: true)
    assert_not @access.reload.can_send?
  end

  test "disconnect clears can_send on every access row" do
    other_agent = @account.agents.create!(name: "Second Sender", model_id: "openrouter/auto")
    other_access = other_agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    grant_send!
    grant_send!(other_access)

    @connection.disconnect!(revoke_provider: false)

    assert_not @access.reload.can_send?
    assert_not other_access.reload.can_send?
    reasons = @connection.comms_send_grant_events.where(action: "withdrawn").pluck(:reason, :actor_user_id)
    assert_equal [ [ "disconnected", nil ], [ "disconnected", nil ] ], reasons
  end

  test "logout, error and suspension clear can_send, and reconnecting does not revive it" do
    %w[reauthorizing error suspended].each do |status|
      @connection.update!(status: "connected")
      grant_send!(@access.reload)
      @connection.update!(status: status)
      assert_not @access.reload.can_send?, status
      assert_equal "not_connected", @connection.comms_send_grant_events.order(:id).last.reason
    end
    @connection.update!(status: "connected")
    assert_not @access.reload.can_send?, "reconnecting does not revive it"
  end

  test "re-pairing clears can_send: a new pairing attempt or login generation" do
    grant_send!
    @connection.update!(status: "reauthorizing")
    assert @connection.restart_pairing!
    @connection.update!(status: "connected")
    assert_not @access.reload.can_send?

    # Even without leaving "connected" (defence in depth): a new session is
    # a new authority.
    grant_send!(@access.reload)
    payload = @connection.reload.credential_payload_hash
    @connection.update!(credential_payload_hash: payload.merge("callback_secret_version" => payload["callback_secret_version"].to_i + 1))
    assert_not @access.reload.can_send?
    assert_equal "repaired", @connection.comms_send_grant_events.order(:id).last.reason

    grant_send!(@access.reload)
    @connection.update!(login_generation: @connection.login_generation + 1)
    assert_not @access.reload.can_send?

    grant_send!(@access.reload)
    @connection.update!(external_subject_id: "447700900999")
    assert_not @access.reload.can_send?
  end

  test "a change of display name alone keeps can_send" do
    grant_send!
    @connection.update!(external_identity: "Daniel (new push name)")
    assert @access.reload.can_send?
  end

  test "an owner change clears can_send" do
    grant_send!
    @connection.update!(connected_by_user: @account_admin)
    assert_not @access.reload.can_send?
    assert_equal "owner_changed", @connection.comms_send_grant_events.order(:id).last.reason
  end

  test "a disconnected connection with grant history is retained" do
    grant_send!
    @connection.disconnect!(revoke_provider: false)
    assert @connection.retained_after_disconnect?
  end

  test "a resident with send grant history cannot be hard-deleted, so the history is never lost" do
    grant_send!
    @access.change_send_grant!(false, actor: @owner)
    assert_equal 0, @agent.comms_sends.count, "no sends, so only the grant history holds it"

    assert_not @agent.destroy
    assert @agent.errors.of_kind?(:base, :"restrict_dependent_destroy.has_many")
    assert Agent.exists?(@agent.id)
    assert_equal 2, CommsSendGrantEvent.where(agent_id: @agent.id).count
  end

  test "a resident with sends cannot be hard-deleted" do
    @connection.comms_sends.create!(agent: @agent, comms_chat: @chat, text: "hi", client_request_id: "keep", status: "sent",
                                    requested_at: Time.current, provider_message_id: "3EB0#{"A" * 16}", connection_generation: 1)
    assert_not @agent.destroy
    assert Agent.exists?(@agent.id)
  end

  test "the manifest offers the send endpoint only to a granted resident while sending is switched on" do
    assert_nil @connection.runtime_credentials(agent: @agent)["send_endpoint"]
    assert_includes @connection.runtime_entry(agent: @agent)["notes"].join, "no way to send"

    grant_send!
    credentials = @connection.reload.runtime_credentials(agent: @agent)
    assert_equal credentials["messages_endpoint"], credentials["send_endpoint"]
    notes = @connection.runtime_entry(agent: @agent)["notes"].join
    assert_includes notes, "AS THE OWNER"
    assert_not_includes notes, "no way to send"
    assert_not credentials.key?("callback_secret")

    without_sending { assert_nil @connection.runtime_credentials(agent: @agent)["send_endpoint"] }
    other = @account.agents.create!(name: "Reader Only", model_id: "openrouter/auto", runtime: "external")
    other.agent_service_accesses.create!(service_connection: @connection, enabled: true)
    assert_nil @connection.runtime_credentials(agent: other)["send_endpoint"]
  end

end
