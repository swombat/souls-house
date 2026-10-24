require "test_helper"

class CommsChatIntegrationStatusTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  self.use_transactional_tests = false

  setup do
    @account = Account.create!(name: "Chat counts #{SecureRandom.hex(4)}", account_type: "team")
    @other_account = Account.create!(name: "Other chat counts #{SecureRandom.hex(4)}", account_type: "team")
    @connection = connection_for(@account)
    @other_connection = connection_for(@other_account)
    @stream = "IntegrationStatus:#{@account.to_param}"
    @other_stream = "IntegrationStatus:#{@other_account.to_param}"
  end

  teardown do
    [ @account, @other_account ].compact.each do |account|
      account.service_connections.reload.each do |connection|
        connection.comms_messages.each(&:destroy!)
        connection.comms_chats.each(&:destroy!)
        connection.comms_messages.reset
        connection.comms_chats.reset
      end
      account.service_connections.reset
      account.destroy!
    end
  end

  test "actual synced and unsynced chat creation and destruction refresh only the owning account" do
    [ {}, { synced: false } ].each do |state|
      chat = nil
      assert_marker { chat = chat_for(sync_state: state) }
      assert_counts(@connection, 1, state.empty? ? 1 : 0)
      assert_marker { chat.destroy! }
      assert_counts(@connection, 0, 0)
    end
  end

  test "effective synced membership matches the SQL summary including missing null and boolean spellings" do
    chat = chat_for
    [
      [ { synced: nil }, 1 ], [ { synced: true }, 1 ],
      [ { synced: "TRUE" }, 1 ], [ { synced: 1 }, 1 ], [ { synced: "yes" }, 1 ],
      [ [], 1 ], [ "not-an-object", 1 ],
      [ { synced: false }, 0 ], [ { synced: "f" }, 0 ], [ { synced: 0 }, 0 ],
      [ { synced: "off" }, 0 ], [ { synced: "NO" }, 0 ],
      [ {}, 1 ], [ { synced: false }, 0 ], [ { synced: nil }, 1 ]
    ].each do |state, expected|
      previous = @connection.send(:comms_summary)[:synced_chats]
      if expected == previous
        assert_no_broadcasts(@stream) { chat.update!(sync_state: state) }
      else
        assert_marker { chat.update!(sync_state: state) }
      end
      assert_counts(@connection, 1, expected)
    end
  end

  test "name kind activity checkpoints and unrelated sync fields stay quiet" do
    chat = chat_for(sync_state: { synced: false })
    assert_no_broadcasts(@stream) do
      chat.update!(name: "SECRET-CHAT-NAME", kind: "group", last_activity_at: Time.current)
      chat.update!(sync_state: { synced: false, reason: "large_group", history_from: 1.day.ago.iso8601,
                               synced_through: Time.current.iso8601, topics: true, deletions_not_applied: 5 })
      chat.update!(provider_chat_id: "renamed-private-id")
      chat.touch
      chat.save!
    end
    assert_counts(@connection, 1, 0)
  end

  test "count invalidation does not introduce validation of malformed legacy synced values" do
    chat = chat_for
    assert_marker { chat.update!(sync_state: { synced: "not-a-boolean" }) }
    assert_equal "not-a-boolean", chat.reload.sync_state["synced"]
    assert_no_broadcasts(@stream) do
      chat.update!(sync_state: { synced: "not-a-boolean", synced_through: Time.current.iso8601 })
    end
    assert_marker { chat.update!(sync_state: { synced: false }) }
    assert_counts(@connection, 1, 0)
  end

  test "invalid creates and restricted destroys do not refresh counts" do
    assert_no_broadcasts(@stream) do
      assert_not @connection.comms_chats.create(provider_chat_id: nil).persisted?
    end
    chat = chat_for
    @connection.comms_messages.create!(comms_chat: chat, provider_message_id: "private",
      sent_at: Time.current, body: "SECRET-BODY")
    assert_no_broadcasts(@stream) { assert_not chat.destroy }
    assert_counts(@connection, 1, 1)
  end

  test "reassignment refreshes both old and new accounts with no private payload" do
    chat = chat_for(sync_state: { synced: false })
    # Prime the association; producers must use the new foreign key, not this cache.
    assert_equal @connection, chat.service_connection
    assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@other_stream) {
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream) {
        chat.update!(service_connection_id: @other_connection.id)
      }
    }
    assert_counts(@connection, 0, 0)
    assert_counts(@other_connection, 1, 0)
    assert_no_broadcasts(@stream) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@other_stream) { chat.destroy! }
    end
    assert_counts(@other_connection, 0, 0)
  end

  test "same-account reassignment refreshes that account once and same connection is quiet" do
    another = connection_for(@account)
    chat = chat_for
    assert_marker { chat.update!(service_connection: another) }
    assert_counts(@connection, 0, 0)
    assert_counts(another, 1, 1)
    assert_no_broadcasts(@stream) { chat.update!(service_connection: another) }
  end

  test "later quiet saves touches and reloads cannot erase a count marker before outer commit" do
    chat = chat_for
    assert_marker do
      CommsChat.transaction do
        assert_no_broadcasts(@stream) do
          chat.update!(sync_state: { synced: false })
          chat.update!(name: "Private")
          chat.touch
          chat.reload
        end
      end
    end
    assert_counts(@connection, 1, 0)
  end

  test "outer and savepoint rollback suppress create destroy membership and reassignment markers" do
    chat = chat_for
    doomed = chat_for(sync_state: { synced: false })
    [ false, true ].each do |savepoint|
      assert_no_broadcasts(@other_stream) do
        assert_no_broadcasts(@stream) do
          CommsChat.transaction do
            CommsChat.transaction(requires_new: savepoint) do
              chat_for
              doomed.destroy!
              chat.update!(sync_state: { synced: false })
              chat.update!(service_connection: @other_connection)
              raise ActiveRecord::Rollback
            end
            raise ActiveRecord::Rollback unless savepoint
          end
        end
      end
      chat.reload
      doomed.reload
      assert_counts(@connection, 2, 1)
      assert_counts(@other_connection, 0, 0)
    end
    assert_marker { chat.update!(sync_state: { synced: false }) }
  end

  test "savepoint rollback neither leaks a marker nor loses a later commit in the outer transaction" do
    chat = chat_for
    assert_marker do
      CommsChat.transaction do
        CommsChat.transaction(requires_new: true) do
          chat.update!(sync_state: { synced: false })
          raise ActiveRecord::Rollback
        end
        assert_no_broadcasts(@stream) do
          chat.reload.update!(sync_state: { synced: false })
          chat.touch
        end
      end
    end
    assert_counts(@connection, 1, 0)
  end

  test "chat upsert and implicit message upsert edit and deletion create count producers only once" do
    now = Time.current
    [
      { type: "chat.upsert", chats: [ { provider_chat_id: "private-explicit", sync_state: { synced: false } } ] },
      { type: "message.upsert", messages: [ { provider_message_id: "1", chat: "private-upsert", sent_at: now.iso8601, body: "SECRET" } ] },
      { type: "message.edit", messages: [ { provider_message_id: "1", chat: "private-edit", edited_at: now.iso8601, body: "SECRET" } ] },
      { type: "message.delete", deletions: [ { provider_message_ids: [ "1" ], chat: "private-delete" } ] }
    ].each_with_index do |event, index|
      assert_marker { receive!(event, seq: index * 2 + 1) }
      assert_no_broadcasts(@stream) { receive!(event, seq: index * 2 + 2) }
      assert_counts(@connection, index + 1, index)
    end
    assert_equal 8, @connection.reload.comms_event_seq
  end

  test "a refused batch rolls back implicitly created chats and their pending markers" do
    assert_no_broadcasts(@stream) do
      assert_raises(CommsEvents::Refused) do
        receive!({
          type: "message.upsert", messages: [
            { provider_message_id: "1", chat: "rolled-back", sent_at: Time.current.iso8601 },
            { provider_message_id: "2", chat: "invalid", sent_at: "invalid" }
          ]
        }, seq: 1)
      end
    end
    assert_counts(@connection, 0, 0)
    assert_equal 0, @connection.reload.comms_event_seq
    assert_equal 0, @connection.comms_messages.count
    assert_marker do
      receive!({ type: "chat.upsert", chats: [ { provider_chat_id: "committed" } ] }, seq: 1)
    end
  end

  private

  def connection_for(account)
    account.service_connections.create!(
      connected_by_user: users(:user_1), provider: "telegram", status: "connected",
      external_subject_id: "synthetic-#{SecureRandom.hex(6)}",
      management_scope: "personal", credential_kind: "session",
      credential_payload_hash: {}, credential_metadata: { credential_strategy: "connector" }
    )
  end

  def chat_for(**attributes)
    @connection.comms_chats.create!({ provider_chat_id: "private-#{SecureRandom.hex(6)}" }.merge(attributes))
  end

  def receive!(event, seq:)
    CommsEvents.receive!(@connection, event.merge(seq:).deep_stringify_keys, nonce: SecureRandom.hex(16))
  end

  def assert_counts(connection, chats, synced)
    assert_equal({ chats:, synced_chats: synced }, connection.send(:comms_summary).slice(:chats, :synced_chats))
  end

  def assert_marker(&block)
    assert_no_broadcasts(@other_stream) do
      assert_equal [ { "action" => "refresh" } ], capture_broadcasts(@stream, &block)
    end
  end

end
