require "test_helper"
require "support/comms_send_helpers"

# The send grant (spec §5): only the owner grants, managers withdraw, defaults
# never grant, and nothing revives a grant once the access row or the
# connection's authority changes.
class CommsSendGrantTest < ActiveSupport::TestCase

  include CommsSendHelpers

  setup { setup_comms_send }

  test "read never implies send: a new access row cannot send" do
    assert @access.enabled?
    assert_not @access.can_send?
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

  test "can_send is only valid on an enabled comms access row" do
    dropbox = @account.service_connections.create!(
      connected_by_user: @owner, provider: "dropbox", external_subject_id: "dbid:grant-test", management_scope: "personal",
      credential_kind: "oauth2", credential_payload_hash: { "access_token" => "t" },
      credential_metadata: { "granted_scopes" => Services::Catalog::DROPBOX_READ, "credential_strategy" => "self_refreshing" }
    )
    access = @agent.agent_service_accesses.create!(service_connection: dropbox, enabled: true)
    assert_not access.update(can_send: true)
    access.reload
    assert_raises(AgentServiceAccess::SendGrantRefused) { access.change_send_grant!(true, actor: @owner) }
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

    @connection.disconnect!

    assert_not @access.reload.can_send?
    assert_not other_access.reload.can_send?
    reasons = @connection.comms_send_grant_events.where(action: "withdrawn").pluck(:reason, :actor_user_id)
    assert_equal [ [ "disconnected", nil ], [ "disconnected", nil ] ], reasons
  end

  test "logout (re-pair) and a change of number clear can_send" do
    grant_send!
    @connection.update!(status: "reauthorizing")
    assert_not @access.reload.can_send?
    assert_equal "repaired", @connection.comms_send_grant_events.order(:id).last.reason

    @connection.update!(status: "connected")
    assert_not @access.reload.can_send?, "reconnecting does not revive it"

    grant_send!
    @connection.update!(external_identity: "+44 7700 900999")
    assert_not @access.reload.can_send?
  end

  test "an owner change clears can_send" do
    grant_send!
    @connection.update!(connected_by_user: @account_admin)
    assert_not @access.reload.can_send?
    assert_equal "owner_changed", @connection.comms_send_grant_events.order(:id).last.reason
  end

  test "a disconnected connection with grant history is retained" do
    grant_send!
    @connection.disconnect!
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

end
