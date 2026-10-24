require "test_helper"

class IntegrationStatusTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Integration commit #{SecureRandom.hex(4)}", account_type: "team")
    @other_account = Account.create!(name: "Integration isolation #{SecureRandom.hex(4)}", account_type: "team")
    @agent = @account.agents.create!(name: "Synthetic integration resident", runtime: "external", model_id: "openrouter/auto")
    @connection = connection_for(@account)
    @stream = "IntegrationStatus:#{@account.to_param}"
    @other_stream = "IntegrationStatus:#{@other_account.to_param}"
    clear_enqueued_jobs
  end

  teardown do
    [ @account, @other_account ].compact.each do |account|
      account.service_connections.each do |connection|
        connection.comms_messages.each(&:destroy!)
        connection.comms_chats.each(&:destroy!)
        connection.comms_messages.reset
        connection.comms_chats.reset
      end
      account.service_connections.reset
      account.destroy!
    end
  end

  test "create update destroy and personal changes carry only an account marker" do
    connection = nil
    assert_marker { connection = connection_for(@account) }
    assert_marker { connection.update!(label: "SECRET-SENTINEL-LABEL") }
    assert_marker { connection.destroy! }
  end

  test "connection allowlist covers rendered lifecycle and configuration" do
    {
      status: "suspended", label: "Renamed", external_identity: "new@example.test",
      management_scope: "account_managed", connected_by_user_id: users(:existing_user).id,
      enabled_for_new_agents: true, freely_provisionable: true, provider: "google_workspace"
    }.each do |column, value|
      messages = capture_broadcasts(@stream) { @connection.update!(column => value) }
      assert_not_empty messages, column.to_s
      assert messages.all? { |message| message == { "action" => "refresh" } }, column.to_s
    end
  end

  test "metadata uses only enumerated presentation keys" do
    assert_equal %w[
      granted_scopes effective_authority requested_authority authority_warnings
      authority_summary credential_strategy search_all_dialogs
    ], ServiceConnection::INTEGRATION_STATUS_METADATA_KEYS
    ServiceConnection::INTEGRATION_STATUS_METADATA_KEYS.each do |key|
      assert_marker do
        @connection.update!(credential_metadata: @connection.credential_metadata.merge(key => true))
      end
    end
  end

  test "availability state and reason and the unpair projection are producers" do
    assert_marker { @connection.update!(connector_state: { availability: { state: "busy" } }) }
    assert_marker { @connection.update!(connector_state: { availability: { state: "busy", reason: "Paused" } }) }
    assert_marker { @connection.update!(connector_state: { unpair: { since: "now", attempts: 1, last_attempt_at: "now" } }) }
    assert_marker { @connection.update!(connector_state: { unpair: { since: "now", attempts: 2, last_attempt_at: "later" } }) }
    assert_marker { @connection.update!(connector_state: {}) }
  end

  test "connection reassignment invalidates old and new accounts" do
    messages = capture_broadcasts(@other_stream) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream) {
        @connection.update!(account: @other_account)
      }
    end
    assert_equal [ { "action" => "refresh" } ], messages
  end

  test "later touch save and reload cannot erase a committed marker" do
    assert_marker do
      ServiceConnection.transaction do
        assert_no_broadcasts(@stream) do
          @connection.update!(label: "Changed")
          @connection.touch
          @connection.update!(credential_metadata: { "unread" => 20 })
          @connection.reload
        end
      end
    end
  end

  test "outer and nested rollbacks do not leak markers or lose later commits" do
    assert_no_broadcasts(@stream) do
      ServiceConnection.transaction do
        @connection.update!(label: "Rolled back")
        @connection.touch
        raise ActiveRecord::Rollback
      end
    end
    @connection.reload
    assert_marker do
      ServiceConnection.transaction do
        ServiceConnection.transaction(requires_new: true) do
          @connection.update!(label: "Savepoint rollback")
          raise ActiveRecord::Rollback
        end
        @connection.reload.update!(label: "Committed")
        assert_no_broadcasts(@stream) { @connection.touch }
      end
    end
    assert_no_broadcasts(@stream) { @connection.update(status: "invalid") }
  end

  test "rolled back connection and access create destroy lifecycles stay silent" do
    access = access_for
    created_id = nil
    assert_no_broadcasts(@stream) do
      ServiceConnection.transaction do
        created = connection_for(@account)
        created_id = created.id
        @agent.agent_service_accesses.create!(service_connection: created, enabled: true)
        access.destroy!
        @connection.destroy!
        raise ActiveRecord::Rollback
      end
    end
    assert_not ServiceConnection.exists?(created_id)
    assert_predicate @connection.reload, :persisted?
    assert_predicate access.reload, :persisted?
  end

  test "secret rotation QR phone sequence and unread state stay silent" do
    assert_no_broadcasts(@stream) do
      @connection.replace_credential_payload_without_reconciliation!("access_token" => "SECRET-SENTINEL-TOKEN")
      @connection.update!(
        credential_payload_hash: { "access_token" => "SECRET-SENTINEL-NEW-TOKEN" },
        credential_revision: @connection.credential_revision + 1,
        credential_fingerprint: "not-a-public-projection",
        credential_metadata: { "unread" => 1, "payload" => "SECRET-SENTINEL-METADATA" },
        pairing_qr: "SECRET-SENTINEL-QR", pairing_qr_issued_at: 2.minutes.ago, pairing_qr_expires_at: 1.minute.ago,
        pairing_phone_code: "12345678", pairing_phone_code_issued_at: 2.minutes.ago, pairing_phone_code_expires_at: 1.minute.ago,
        comms_event_seq: 1, login_generation: 1,
        connector_state: { login: { step: "password" }, unread: 2, phone_pairing: { step: "code" }, phone_request_seq: 1 }
      )
      @connection.update_columns(comms_event_seq: 2)
      @connection.clear_expired_pairing_qr!
      @connection.clear_expired_pairing_phone_code!
      @connection.touch
    end
  end

  test "unread availability bookkeeping and unpair error class alone stay silent" do
    @connection.update!(connector_state: {
      availability: { state: "busy", reason: "Paused" },
      unpair: { since: "now", attempts: 1, last_attempt_at: "now", last_error: "Old" }
    })
    assert_no_broadcasts(@stream) do
      @connection.update!(connector_state: {
        availability: { state: "busy", reason: "Paused", since: "later", retry_after: 4, token: "SECRET" },
        unpair: { since: "now", attempts: 1, last_attempt_at: "now", last_error: "New" },
        unread: 99
      })
    end
  end

  test "ordinary comms history checkpoints edits and tombstones do not emit" do
    chat = @connection.comms_chats.create!(provider_chat_id: "synthetic", kind: "direct", name: "Secret chat")
    assert_no_broadcasts(@stream) do
      message = @connection.comms_messages.create!(comms_chat: chat, provider_message_id: "1", sent_at: Time.current, body: "SECRET-SENTINEL-BODY")
      message.update!(body: "Edited", edited_at: Time.current)
      message.tombstone!(at: Time.current)
      chat.update!(sync_state: { synced: true, synced_through: Time.current.iso8601 }, last_activity_at: Time.current)
      @connection.update_columns(comms_event_seq: 3)
    end
  end

  test "sequenced existing-chat traffic stays silent but availability survives sequence acknowledgement" do
    @connection.update!(provider: "telegram", credential_metadata: { credential_strategy: "connector" })
    @connection.comms_chats.create!(provider_chat_id: "user:1", kind: "direct", name: "Synthetic")
    now = Time.current
    events = [
      { type: "chat.upsert", chats: [ { provider_chat_id: "user:1", kind: "direct", name: "Synthetic" } ] },
      { type: "message.upsert", messages: [ { provider_message_id: "1", chat: "user:1", sent_at: now.iso8601, body: "SECRET-BODY" } ] },
      { type: "message.edit", messages: [ { provider_message_id: "1", chat: "user:1", edited_at: (now + 1.second).iso8601, body: "Edited" } ] },
      { type: "sync.checkpoint", chats: [ { provider_chat_id: "user:1", synced_through: now.iso8601 } ] },
      { type: "message.delete", deletions: [ { provider_message_ids: [ "1" ], chat: "user:1" } ], unresolved: 1 }
    ]
    assert_no_broadcasts(@stream) do
      events.each_with_index do |event, index|
        CommsEvents.receive!(@connection, event.merge(seq: index + 1).deep_stringify_keys, nonce: SecureRandom.hex(16))
      end
    end
    assert_equal 5, @connection.reload.comms_event_seq
    assert_marker do
      CommsEvents.receive!(@connection, {
        "seq" => 6, "type" => "connector.availability", "state" => "busy", "reason" => "Synthetic"
      }, nonce: SecureRandom.hex(16))
    end
    assert_equal 6, @connection.reload.comms_event_seq
  end

  test "sequenced QR and phone pairing events never invalidate integration status" do
    @connection.update!(provider: "whatsapp", status: "pairing")
    now = Time.current
    assert_no_broadcasts(@stream) do
      CommsEvents.receive!(@connection, {
        "seq" => 1, "attempt" => 1, "type" => "pairing.qr", "code" => "SECRET-QR",
        "issued_at" => now.iso8601, "expires_at" => (now + 30.seconds).iso8601
      }, nonce: SecureRandom.hex(16))
      request = @connection.request_phone_pairing!(1)
      CommsEvents.receive!(@connection, {
        "seq" => 2, "attempt" => 1, "type" => "pairing.phone_code", "code" => "ABCD-EFGH",
        "request_id" => request, "issued_at" => now.iso8601, "expires_at" => (now + 30.seconds).iso8601
      }, nonce: SecureRandom.hex(16))
    end
    assert_equal 2, @connection.reload.comms_event_seq
    assert_equal "ABCDEFGH", @connection.pairing_phone_code
  end

  test "access lifecycle linkage and explicit allowlisted fields emit" do
    access = nil
    assert_marker { access = access_for }
    {
      enabled: false, follows_default: true,
      provisioning_status: "failed", provisioning_error_code: "synthetic_failure",
      agent: @account.agents.create!(name: "Another synthetic resident", runtime: "external", model_id: "openrouter/auto"),
      service_connection: connection_for(@account)
    }.each do |column, value|
      assert_marker { access.update!(column => value) }
    end
    assert_no_broadcasts(@stream) do
      access.touch
      access.update!(provisioned_revision: 12, provisioned_at: Time.current)
    end
    assert_marker { access.destroy! }
  end

  test "access write survives a later touch and outer rollback is silent" do
    access = access_for
    assert_marker do
      AgentServiceAccess.transaction do
        assert_no_broadcasts(@stream) do
          access.update!(follows_default: true)
          access.touch
          access.save!
        end
      end
    end
    assert_no_broadcasts(@stream) do
      AgentServiceAccess.transaction do
        access.update!(provisioning_status: "failed")
        access.touch
        raise ActiveRecord::Rollback
      end
    end
  end

  test "pending update_columns emits at outer commit with unchanged enqueue semantics" do
    access = access_for
    @agent.update!(container_name: "synthetic-not-started")
    access.update!(provisioning_status: "provisioned", provisioning_error_code: "old")
    clear_enqueued_jobs
    assert_enqueued_jobs 1, only: AccountAgentCredentialsRefreshJob do
      assert_marker do
        AgentServiceAccess.transaction do
          assert_no_broadcasts(@stream) { access.schedule_reconciliation! }
        end
      end
    end
    assert_equal "pending", access.reload.provisioning_status
    assert_nil access.provisioning_error_code
    assert_no_broadcasts(@stream) { access.schedule_reconciliation! }
    access.update!(provisioning_status: "provisioned")
    assert_no_broadcasts(@stream) do
      AgentServiceAccess.transaction do
        access.schedule_reconciliation!
        raise ActiveRecord::Rollback
      end
    end
    assert_equal "provisioned", access.reload.provisioning_status
  end

  test "manifest bulk writes retain compare and set and outer commit behavior" do
    access = access_for
    manifest = Agents::ServiceManifest.new(@agent)
    manifest.to_h
    assert_no_enqueued_jobs(only: AccountAgentCredentialsRefreshJob) do
      assert_marker do
        AgentServiceAccess.transaction do
          assert_no_broadcasts(@stream) { manifest.mark_reconciled! }
        end
      end
    end
    assert_equal "provisioned", access.reload.provisioning_status
    [ -> { access.update!(enabled: false) },
      -> { access.touch },
      -> { @connection.update!(credential_revision: @connection.credential_revision + 1) },
      -> { @connection.update!(status: "suspended") } ].each do |change|
      snapshot = Agents::ServiceManifest.new(@agent)
      snapshot.to_h
      change.call
      assert_no_broadcasts(@stream) { snapshot.mark_reconciled! }
    end
    @connection.update!(status: "connected")
    snapshot = Agents::ServiceManifest.new(@agent)
    snapshot.to_h
    assert_no_broadcasts(@stream) do
      AgentServiceAccess.transaction do
        snapshot.mark_reconciled!
        raise ActiveRecord::Rollback
      end
    end
    assert_marker { snapshot.mark_reconciled! }
    assert_equal "removed", access.reload.provisioning_status
  end

  test "VM failure bulk marker only follows affected accesses and waits for commit" do
    access = access_for
    placement = AgentPlacement.create!(agent: @agent, backend: "local", state: "pending")
    fail_refresh = ->(ids) do
      Agents::RemoteRuntime.record_refresh_problem!(placement, @agent,
        { "accesses" => ids.map { |id| { "id" => id } } }, "failed", "synthetic", Time.current)
    end
    assert_marker do
      AgentServiceAccess.transaction do
        assert_no_broadcasts(@stream) { fail_refresh.call([ access.id ]) }
      end
    end
    assert_equal "failed", access.reload.provisioning_status
    assert_equal "vm_restart_failed", access.provisioning_error_code
    assert_no_broadcasts(@stream) { fail_refresh.call([ -1 ]) }
    assert_no_broadcasts(@stream) do
      AgentServiceAccess.transaction do
        fail_refresh.call([ access.id ])
        raise ActiveRecord::Rollback
      end
    end
  end

  test "retained unpair failure and clear bypasses emit without real connector calls" do
    @connection.comms_chats.create!(provider_chat_id: "retained", kind: "direct")
    assert_marker do
      ServiceConnection.transaction do
        assert_no_broadcasts(@stream) { assert_equal true, @connection.record_unpair_failure!(IOError.new) }
      end
    end
    assert_no_broadcasts(@stream) do
      ServiceConnection.transaction do
        @connection.record_unpair_failure!(IOError.new)
        raise ActiveRecord::Rollback
      end
    end
    @connection.reload
    CommsConnector.stub(:unpair!, ->(*) { raise IOError, "synthetic" }) do
      assert_marker { assert_equal false, @connection.retry_unpair! }
    end
    CommsConnector.stub(:unpair!, true) do
      assert_no_broadcasts(@stream) do
        ServiceConnection.transaction do
          @connection.retry_unpair!
          raise ActiveRecord::Rollback
        end
      end
      assert @connection.reload.unpair_pending?
      assert_marker { assert_equal true, @connection.retry_unpair! }
      assert_predicate @connection.reload, :persisted?
      assert_not @connection.unpair_pending?
      assert_no_broadcasts(@stream) { @connection.retry_unpair! }
    end
  end

  private

  def connection_for(account)
    account.service_connections.create!(
      connected_by_user: users(:user_1), provider: "dropbox",
      external_subject_id: "synthetic-#{SecureRandom.hex(6)}",
      management_scope: "personal", credential_kind: "oauth2",
      credential_payload_hash: { "access_token" => "synthetic-private" }
    )
  end

  def access_for
    @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
  end

  def assert_marker(&block)
    assert_no_broadcasts(@other_stream) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream, &block)
    end
  end

end
