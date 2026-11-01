require "test_helper"
require "support/comms_send_helpers"

# Round 1 of Mira's review of #706 (JWblqj, emWQxJ): three interleavings and
# boundaries she reproduced against 63de614c, kept as regressions with
# committed rows (no transactional tests: the race needs two connections).
# Its own class, not a subclass of GuestIntegrationGrantTest: a subclass
# would inherit and rerun every one of those tests without transactions.
class GuestIntegrationGrantRaceTest < ActiveSupport::TestCase

  include CommsSendHelpers
  self.use_transactional_tests = false

  DRIVE_READ = "https://www.googleapis.com/auth/drive.readonly".freeze
  DRIVE_WRITE = "https://www.googleapis.com/auth/drive".freeze

  setup do
    @daniel = users(:user_1)
    @anna = users(:existing_user)
    @home = accounts(:personal_account)
    @sharing = accounts(:team_account)
    @lume = agents(:research_assistant)
    @seat = @sharing.guest_memberships.create!(agent: @lume, added_by: @daniel)
    @connection = @sharing.service_connections.create!(
      connected_by_user: @anna, provider: "google_workspace",
      external_subject_id: "google-anna", external_identity: "google-anna@example.test",
      management_scope: "personal", credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "anna-access", "refresh_token" => "anna-refresh", "expires_at" => 2.days.from_now.utc.iso8601 },
      credential_metadata: { "credential_strategy" => "refresh_broker", "granted_scopes" => [ DRIVE_READ ] }
    )
  end

  teardown do
    ids = ServiceConnection.where(account_id: @sharing.id, external_subject_id: [ "google-anna" ]).pluck(:id)
    ids += Array(@whatsapp&.id)
    CommsSend.where(service_connection_id: ids).delete_all
    CommsChat.where(service_connection_id: ids).delete_all
    CommsSendGrantEvent.where(service_connection_id: ids).delete_all
    GuestAccessApprovalEvent.where(service_connection_id: ids).delete_all
    AgentServiceAccess.where(service_connection_id: ids).delete_all
    ServiceConnection.where(id: ids).delete_all
    GuestMembership.where(id: @seat.id).delete_all
  end

  # Mira's interleaving: the scopes widen in one transaction, held open after
  # its callbacks ran; the home approves the old request meanwhile. The
  # approval now takes the connection's lock first, so it waits for the
  # widening, then sees it and re-asks rather than approving what it was
  # never shown. (Her version ran the approval on the test thread, which
  # would now block on the held lock until the holder timed out; here the
  # approval has its own thread and the holder is released while it waits.)
  test "an authority change racing an approval never leaves widened access approved" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    changed = Concurrent::CountDownLatch.new(1)
    release = Concurrent::CountDownLatch.new(1)
    changer = in_thread do
      ServiceConnection.transaction do
        connection = ServiceConnection.find(@connection.id)
        connection.update!(credential_metadata: connection.credential_metadata.merge("granted_scopes" => [ DRIVE_WRITE ]))
        changed.count_down
        raise "release timeout" unless release.wait(10)
      end
    end
    assert changed.wait(5)
    approver = in_thread { AgentServiceAccess.find(access.id).approve_home!(actor: @daniel, generation: 1) }
    sleep 0.3
    assert approver.alive?, "the approval should be waiting for the authority change to commit"
    release.count_down
    assert_thread_ok(changer)
    assert_thread_raised(approver, AgentServiceAccess::HomeApprovalRefused)

    access.reload
    assert_equal "pending", access.home_approval
    assert_not access.effective?
    assert_not access.home_approval_stale?
    assert_equal [ DRIVE_WRITE ], access.home_approval_authority["granted_scopes"]
    assert_operator access.home_approval_generation, :>, 1
  end

  test "a pending guest send grant cannot be claimed" do
    with_send_providers("whatsapp") do
      @whatsapp = build_whatsapp_connection(@sharing, @anna)
      access = @lume.set_service_access!(@whatsapp, enabled: true, actor: @anna)
      access.change_send_grant!(true, actor: @anna)
      assert_equal "pending", access.reload.home_approval
      chat = @whatsapp.comms_chats.create!(provider_chat_id: "review@example.test", kind: "direct")
      refusal = assert_raises(CommsSending::Refused) do
        CommsSending.claim!(connection: @whatsapp, agent: @lume, chat: chat, text: "synthetic", client_request_id: "review-706")
      end
      assert_equal :send_not_granted, refusal.code
      assert_equal 0, CommsSend.where(service_connection_id: @whatsapp.id).count
    end
  end

  test "a send claimed while approved is refused at dispatch once the approval is re-asked" do
    with_send_providers("whatsapp") do
      @whatsapp = build_whatsapp_connection(@sharing, @anna)
      access = @lume.set_service_access!(@whatsapp, enabled: true, actor: @anna)
      access.approve_home!(actor: @daniel, generation: access.home_approval_generation)
      access.change_send_grant!(true, actor: @anna)
      access.reload.approve_home!(actor: @daniel, generation: access.home_approval_generation)
      assert access.reload.effective?
      chat = @whatsapp.comms_chats.create!(provider_chat_id: "review@example.test", kind: "direct")
      send, = CommsSending.claim!(connection: @whatsapp, agent: @lume, chat: chat, text: "synthetic", client_request_id: "review-706-dispatch")
      assert_equal "pending", send.status

      @whatsapp.reload.update!(credential_metadata: @whatsapp.credential_metadata.merge("granted_scopes" => [ "widened" ]))
      assert_equal "pending", access.reload.home_approval

      assert_not CommsSending.dispatch!(send.reload)
      assert_equal [ "failed", "refused_at_dispatch_send_not_granted" ], send.reload.values_at(:status, :error_code)
    end
  end

  test "the sweeper's selected old request does not expire a renewed one" do
    access = @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    access.update_columns(home_approval_requested_at: 15.days.ago)
    selected = AgentServiceAccess.awaiting_home_approval
      .where(home_approval_requested_at: ..AgentServiceAccess::REQUEST_EXPIRY.ago).find(access.id)
    @lume.set_service_access!(@connection, enabled: false, actor: @anna)
    @lume.set_service_access!(@connection, enabled: true, actor: @anna)
    selected.expire_home!
    assert_equal "pending", access.reload.home_approval
    assert access.enabled?
  end

end
