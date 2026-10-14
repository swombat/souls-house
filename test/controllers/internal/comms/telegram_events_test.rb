require "test_helper"
require "support/telegram_comms_helpers"

module Internal
  module Comms
    # Telegram's events (proposal 2026-10-11): chat-scoped identity, edits,
    # tombstones, sync state, sequenced acknowledgement, and login events
    # bound to the login generation.
    class TelegramEventsTest < ActionDispatch::IntegrationTest

      include TelegramCommsHelpers

      setup do
        @user = users(:user_1)
        @account = accounts(:personal_account)
        @connection = telegram_connection(account: @account, user: @user)
      end

      test "the same message id in two peers is two messages" do
        post_telegram_event @connection, messages("user:1" => "42", "channel:9" => "42")
        assert_response :no_content

        assert_equal 2, @connection.comms_messages.where(provider_message_id: "42").count
        assert_equal %w[channel:9 user:1], @connection.comms_chats.pluck(:provider_chat_id).sort
      end

      test "a duplicate delivery is ignored and keeps the first body" do
        post_telegram_event @connection, messages("user:1" => "7")
        post_telegram_event @connection, messages({ "user:1" => "7" }, body: "changed")

        assert_equal "hello 7", @connection.comms_messages.sole.body
      end

      test "edits replace content in edit order, and an older edit never wins" do
        post_telegram_event @connection, messages("user:1" => "7")
        post_telegram_event @connection, edit("user:1", "7", "second", "2026-10-12T10:05:00Z")
        post_telegram_event @connection, edit("user:1", "7", "first", "2026-10-12T10:01:00Z")

        message = @connection.comms_messages.sole
        assert_equal "second", message.body
        assert_equal Time.iso8601("2026-10-12T10:05:00Z"), message.edited_at
        assert_equal "2026-10-12T10:05:00Z", message.as_comms_json[:edited_at]
      end

      test "a deletion tombstones the row, and no edit, retry or backfill brings it back" do
        post_telegram_event @connection, messages("user:1" => "7")
        post_telegram_event @connection, deletion("user:1", %w[7])

        message = @connection.comms_messages.sole
        assert message.deleted?
        assert_nil message.body
        assert_equal true, message.as_comms_json[:deleted]

        post_telegram_event @connection, messages("user:1" => "7")
        post_telegram_event @connection, edit("user:1", "7", "resurrected", "2026-10-12T11:00:00Z")
        message.reload
        assert message.deleted?
        assert_nil message.body
        assert_nil message.caption
      end

      test "a deletion that arrives before its message leaves a tombstone the message cannot fill" do
        post_telegram_event @connection, deletion("user:1", %w[8])
        post_telegram_event @connection, messages("user:1" => "8")

        message = @connection.comms_messages.sole
        assert message.deleted?
        assert_nil message.body
      end

      test "a placeholder from an early edit gets its sender and time from the original, and keeps the edit" do
        post_telegram_event @connection, edit("user:1", "9", "current", "2026-10-12T10:05:00Z")
        message = @connection.comms_messages.sole
        assert message.placeholder?
        assert_equal true, message.as_comms_json[:provisional]

        post_telegram_event @connection, messages("user:1" => "9")
        message.reload
        assert_not message.placeholder?
        assert_equal "current", message.body
        assert_equal "Ann", message.sender_name
        assert_equal Time.iso8601("2026-10-12T10:00:00Z"), message.sent_at
      end

      test "a later delivery carrying a newer edit updates the content; an older one does not" do
        post_telegram_event @connection, messages("user:1" => "7")
        newer = messages({ "user:1" => "7" }, body: "edited")
        newer[:messages].first[:edited_at] = "2026-10-12T10:10:00Z"
        post_telegram_event @connection, newer
        assert_equal "edited", @connection.comms_messages.sole.body

        older = messages({ "user:1" => "7" }, body: "older edit")
        older[:messages].first[:edited_at] = "2026-10-12T10:02:00Z"
        post_telegram_event @connection, older
        assert_equal "edited", @connection.comms_messages.sole.body
      end

      test "an early deletion's tombstone gets the original's time but never its content" do
        post_telegram_event @connection, deletion("user:1", %w[8])
        post_telegram_event @connection, messages("user:1" => "8")
        message = @connection.comms_messages.sole
        assert message.deleted?
        assert_nil message.body
        assert_equal Time.iso8601("2026-10-12T10:00:00Z"), message.sent_at
      end

      test "sequenced obsolete lifecycle events are acknowledged as skipped and the outbox moves on" do
        pairing = telegram_connection(account: @account, user: @user, status: "pairing", generation: 2)
        expired = qr(generation: 2).merge(seq: 1, expires_at: 1.second.ago.utc.iso8601)
        post_telegram_event pairing, expired
        assert_response :ok
        assert_equal({ "committed_seq" => 1, "skipped" => "expired_qr" }, response.parsed_body)
        assert_nil pairing.reload.pairing_qr

        post_telegram_event pairing, { type: "login.failed", generation: 1, code: "expired", seq: 2 }
        assert_equal "stale_generation", response.parsed_body["skipped"]
        assert_equal({}, pairing.reload.login_state)

        post_telegram_event pairing, { type: "status.changed", status: "connected", generation: 2, seq: 3, identity: { user_id: "9" } }
        assert_equal({ "committed_seq" => 3 }, response.parsed_body)
        post_telegram_event pairing, messages("user:1" => "1").merge(seq: 4)
        post_telegram_event pairing, { type: "sync.checkpoint", seq: 5, chats: [ { provider_chat_id: "user:1", synced_through: "2026-10-12T10:00:00Z" } ] }
        assert_equal 5, response.parsed_body["committed_seq"]
        assert_equal "connected", pairing.reload.status

        post_telegram_event pairing, qr(generation: 2).merge(seq: 6)
        assert_equal "connection_not_accepting", response.parsed_body["skipped"]
      end

      test "unsequenced, an obsolete event is still refused, and a malformed sequenced one is never skipped" do
        pairing = telegram_connection(account: @account, user: @user, status: "pairing", generation: 2)
        post_telegram_event pairing, qr(generation: 1)
        assert_response :conflict

        post_telegram_event pairing, { type: "login.failed", generation: 2, code: "weird", seq: 1 }
        assert_response :unprocessable_entity
        assert_equal 0, pairing.reload.comms_event_seq
      end

      test "a Telegram sign-in cannot finish without naming its attempt, by either event shape" do
        pairing = telegram_connection(account: @account, user: @user, status: "pairing", generation: 2)
        post_telegram_event pairing, { type: "status.changed", status: "connected", identity: { user_id: "x" } }
        assert_response :conflict
        post_telegram_event pairing, { type: "pairing.qr", code: "tg://login?token=x", issued_at: Time.current.utc.iso8601,
                                       expires_at: 30.seconds.from_now.utc.iso8601 }
        assert_response :conflict
        assert_equal "pairing", pairing.reload.status
        assert_nil pairing.pairing_qr
      end

      test "once connected, a status change from another attempt cannot change identity or log out" do
        @connection.update!(external_subject_id: "current", external_identity: "Current")
        post_telegram_event @connection, { type: "status.changed", status: "connected", identity: { user_id: "other" } }
        assert_response :conflict
        post_telegram_event @connection, { type: "status.changed", status: "logged_out", generation: 0 }
        assert_response :conflict
        assert_equal [ "connected", "current" ], [ @connection.reload.status, @connection.external_subject_id ]

        post_telegram_event @connection, { type: "status.changed", status: "logged_out", generation: 1 }
        assert_response :no_content
        assert_equal "reauthorizing", @connection.reload.status
      end

      test "deletions the connector could not place are counted, not guessed" do
        post_telegram_event @connection, { type: "message.delete", deletions: [], unresolved: 3 }
        post_telegram_event @connection, { type: "message.delete", deletions: [], unresolved: 2 }

        assert_equal 5, @connection.reload.connector_state["deletions_not_applied"]
        assert_equal 0, @connection.comms_messages.count
      end

      test "a deletion in one peer leaves the same id in another peer alone" do
        post_telegram_event @connection, messages("user:1" => "42", "channel:9" => "42")
        post_telegram_event @connection, deletion("channel:9", %w[42])

        assert_not @connection.comms_chats.find_by!(provider_chat_id: "user:1").comms_messages.sole.deleted?
        assert @connection.comms_chats.find_by!(provider_chat_id: "channel:9").comms_messages.sole.deleted?
      end

      test "sync state is recorded, synced_through only moves forward, and unknown reasons are refused" do
        post_telegram_event @connection, { type: "chat.upsert", chats: [
          { provider_chat_id: "channel:5", name: "News", kind: "channel",
            sync_state: { synced: false, reason: "broadcast_channel" } },
          { provider_chat_id: "channel:6", name: "Club", kind: "supergroup",
            sync_state: { synced: true, topics: "unsupported", history_from: "2026-09-12T00:00:00Z",
                          synced_through: "2026-10-12T10:00:00Z" } }
        ] }
        assert_response :no_content
        post_telegram_event @connection, { type: "sync.checkpoint", chats: [ { provider_chat_id: "channel:6", synced_through: "2026-10-12T09:00:00Z" } ] }
        post_telegram_event @connection, { type: "sync.checkpoint", chats: [ { provider_chat_id: "channel:6", synced_through: "2026-10-12T11:00:00Z" } ] }

        news, club = @connection.comms_chats.order(:provider_chat_id).to_a
        assert_equal({ "synced" => false, "reason" => "broadcast_channel" }, news.sync_state)
        assert_equal "2026-10-12T11:00:00Z", club.sync_state["synced_through"]
        assert_equal "unsupported", club.as_comms_json[:sync_state]["topics"]

        post_telegram_event @connection, { type: "chat.upsert", chats: [ { provider_chat_id: "channel:7", sync_state: { synced: false, reason: "because" } } ] }
        assert_response :unprocessable_entity
      end

      test "sequenced events are acknowledged in order, exactly once, and a gap is refused" do
        post_telegram_event @connection, messages("user:1" => "1").merge(seq: 1)
        assert_response :ok
        assert_equal 1, response.parsed_body["committed_seq"]

        post_telegram_event @connection, messages("user:1" => "3").merge(seq: 3)
        assert_response :conflict
        assert_equal({ "error" => "sequence_gap", "committed_seq" => 1 }, response.parsed_body)
        assert_nil @connection.comms_messages.find_by(provider_message_id: "3")

        post_telegram_event @connection, messages("user:1" => "2").merge(seq: 2)
        assert_equal 2, response.parsed_body["committed_seq"]
        post_telegram_event @connection, messages({ "user:1" => "2" }, body: "replayed").merge(seq: 2)
        assert_response :ok
        assert_equal 2, response.parsed_body["committed_seq"]
        assert_equal 2, @connection.reload.comms_event_seq
      end

      test "login events for an older generation are refused" do
        pairing = telegram_connection(account: @account, user: @user, status: "pairing", generation: 3)

        post_telegram_event pairing, qr(generation: 2)
        assert_response :conflict
        assert_equal "stale_generation", response.parsed_body["error"]
        assert_nil pairing.reload.pairing_qr

        post_telegram_event pairing, qr(generation: 3)
        assert_response :no_content
        assert pairing.reload.current_pairing_qr
      end

      test "a two-step password request clears the QR and records the hint, and a wrong password keeps the step" do
        pairing = telegram_connection(account: @account, user: @user, status: "pairing", generation: 1)
        post_telegram_event pairing, qr(generation: 1)
        post_telegram_event pairing, { type: "login.password_required", generation: 1, hint: "dog's name" }
        assert_response :no_content
        pairing.reload
        assert_nil pairing.pairing_qr
        assert_equal({ "step" => "password", "hint" => "dog's name" }, pairing.login_state)

        post_telegram_event pairing, { type: "login.failed", generation: 1, code: "password_invalid" }
        assert_equal "password", pairing.reload.login_state["step"]
        assert_equal "password_invalid", pairing.login_state["error"]

        post_telegram_event pairing, { type: "login.failed", generation: 1, code: "flood_wait", retry_after: 120 }
        assert_nil pairing.reload.login_state["step"]
        assert_equal 120, pairing.login_state["retry_after"]
      end

      test "connected carries the Telegram identity and clears the login state" do
        pairing = telegram_connection(account: @account, user: @user, status: "pairing", generation: 1)
        post_telegram_event pairing, { type: "login.password_required", generation: 1 }
        post_telegram_event pairing, { type: "status.changed", status: "connected", generation: 1,
                                       identity: { user_id: "777", display_name: "Daniel", username: "swombat" } }
        assert_response :no_content

        pairing.reload
        assert_equal "connected", pairing.status
        assert_equal "777", pairing.external_subject_id
        assert_equal "Daniel @swombat", pairing.external_identity
        assert_equal({}, pairing.login_state)
      end

      test "a phone sign-in's code step clears the QR, records only where the code went, and a late QR cannot return" do
        pairing = telegram_connection(account: @account, user: @user, status: "pairing", generation: 2)
        post_telegram_event pairing, qr(generation: 2)
        assert pairing.reload.current_pairing_qr

        post_telegram_event pairing, { type: "login.code_sent", generation: 1, delivery: "app" }
        assert_response :conflict
        assert_equal "stale_generation", response.parsed_body["error"]
        post_telegram_event pairing, { type: "login.code_sent", generation: 2, delivery: "carrier pigeon" }
        assert_response :unprocessable_entity

        post_telegram_event pairing, { type: "login.code_sent", generation: 2, delivery: "app", length: 5,
                                       next_delivery: "sms", timeout: 60, phone: "+447700900123" }
        assert_response :no_content
        pairing.reload
        assert_nil pairing.pairing_qr
        assert_equal({ "step" => "code", "delivery" => "app", "length" => 5, "next_delivery" => "sms", "timeout" => 60 },
                     pairing.login_state)
        assert_not_includes pairing.attributes.to_json, "7700900123"

        # A QR code still in flight from before the owner chose the number.
        post_telegram_event pairing, qr(generation: 2).merge(issued_at: 1.second.from_now.utc.iso8601)
        assert_response :conflict
        assert_equal "stale_qr", response.parsed_body["error"]
        assert_nil pairing.reload.pairing_qr

        # The code is right but the account has a password: the next step.
        post_telegram_event pairing, { type: "login.password_required", generation: 2, hint: "tea" }
        assert_equal({ "step" => "password", "hint" => "tea" }, pairing.reload.login_state)
        post_telegram_event pairing, { type: "login.code_sent", generation: 2, delivery: "app" }
        assert_response :conflict
        assert_equal "password", pairing.reload.login_state["step"]

        # An attempt that has ended stays ended: a code_sent behind its
        # expiry does not revive it.
        post_telegram_event pairing, { type: "login.failed", generation: 2, code: "expired" }
        assert_response :no_content
        post_telegram_event pairing, { type: "login.code_sent", generation: 2, delivery: "app" }
        assert_response :conflict
        assert_equal({ "error" => "expired" }, pairing.reload.login_state.slice("error", "step"))
      end

      test "the pool's availability is recorded for the connection" do
        post_telegram_event @connection, { type: "connector.availability", state: "backlogged", reason: "outbox_full", since: "2026-10-12T10:00:00Z" }
        assert_response :no_content
        assert_equal "backlogged", @connection.reload.connector_availability["state"]

        post_telegram_event @connection, { type: "connector.availability", state: "sleepy" }
        assert_response :unprocessable_entity
      end

      private

      # Braceless string-keyed pairs arrive as keywords, so collect both.
      def messages(peers = {}, body: nil, **more)
        peers = peers.merge(more)
        {
          type: "message.upsert",
          messages: peers.map do |chat, id|
            { provider_message_id: id, chat: chat, sender_id: "user:1", sender_name: "Ann",
              sent_at: "2026-10-12T10:00:00Z", body: body || "hello #{id}", media_kind: nil, caption: nil }
          end
        }
      end

      def edit(chat, id, body, edited_at)
        { type: "message.edit", messages: [ { chat: chat, provider_message_id: id, body: body, caption: nil, edited_at: edited_at } ] }
      end

      def deletion(chat, ids)
        { type: "message.delete", deletions: [ { chat: chat, provider_message_ids: ids, deleted_at: "2026-10-12T10:30:00Z" } ] }
      end

      def qr(generation:)
        { type: "login.qr", generation: generation, code: "tg://login?token=abc#{generation}",
          issued_at: Time.current.utc.iso8601, expires_at: 30.seconds.from_now.utc.iso8601 }
      end

    end
  end
end
