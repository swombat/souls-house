require "test_helper"

module Internal
  module Comms
    class EventsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:user_1)
        @account = accounts(:personal_account)
        @connection = whatsapp_connection(status: "connected")
        @other = whatsapp_connection(status: "connected")
      end

      test "a validly signed message batch upserts chats and messages" do
        assert_difference -> { CommsMessage.count } => 2, -> { CommsChat.count } => 1 do
          post_event @connection, message_event("m1", "m2")
        end
        assert_response :no_content

        chat = @connection.comms_chats.sole
        assert_equal "447700900123@s.whatsapp.net", chat.provider_chat_id
        assert_equal Time.iso8601("2026-10-09T10:01:00Z"), chat.last_activity_at
        message = @connection.comms_messages.find_by!(provider_message_id: "m1")
        assert_equal "hello m1", message.body
        assert_equal "Alice", message.sender_name
      end

      test "a replayed identical message is a no-op" do
        post_event @connection, message_event("m1")
        message = @connection.comms_messages.sole
        updated_at = message.updated_at

        travel 1.second do
          assert_no_difference -> { CommsMessage.count } do
            post_event @connection, message_event("m1")
          end
        end
        assert_response :no_content
        assert_equal updated_at, message.reload.updated_at
      end

      test "chat upserts are idempotent and keep the newest activity" do
        event = { type: "chat.upsert", chats: [ { provider_chat_id: "g1@g.us", name: "Family", kind: "group", last_activity_at: "2026-10-09T09:00:00Z" } ] }
        post_event @connection, event
        post_event @connection, event.merge(chats: [ event[:chats].first.merge(last_activity_at: "2026-10-08T09:00:00Z") ])

        chat = @connection.comms_chats.sole
        assert_equal "Family", chat.name
        assert_equal Time.iso8601("2026-10-09T09:00:00Z"), chat.last_activity_at
      end

      test "a bad signature is refused and writes nothing" do
        body = JSON.generate(message_event("m1"))
        headers = signed_headers(@connection, body).merge("X-Comms-Signature" => "0" * 64)

        assert_nothing_written do
          post events_path(@connection), params: body, headers: headers
        end
        assert_response :unauthorized
        assert_equal "bad_signature", response.parsed_body["error"]
      end

      test "an unsigned request is refused" do
        assert_nothing_written do
          post events_path(@connection), params: JSON.generate(message_event("m1")), headers: { "Content-Type" => "application/json" }
        end
        assert_response :unauthorized
      end

      test "a request signed for connection A is refused for connection B" do
        body = JSON.generate(message_event("m1"))
        headers = signed_headers(@connection, body, path: events_path(@other))

        assert_nothing_written do
          post events_path(@other), params: body, headers: headers
        end
        assert_response :unauthorized
        assert_equal "connection_mismatch", response.parsed_body["error"]

        # Even claiming B's id, A's secret does not produce B's signature.
        forged = CommsSignature.headers_for(
          secret: secret_for(@connection), connection_id: @other.public_id,
          method: "POST", path: events_path(@other), body: body
        )
        assert_nothing_written do
          post events_path(@other), params: body, headers: forged.merge("Content-Type" => "application/json")
        end
        assert_response :unauthorized
        assert_equal "bad_signature", response.parsed_body["error"]
      end

      test "a stale timestamp is refused" do
        body = JSON.generate(message_event("m1"))
        headers = signed_headers(@connection, body, now: 6.minutes.ago)

        assert_nothing_written do
          post events_path(@connection), params: body, headers: headers
        end
        assert_response :unauthorized
        assert_equal "stale_timestamp", response.parsed_body["error"]
      end

      test "a reused nonce is refused and writes nothing" do
        first = JSON.generate(message_event("m1"))
        nonce = SecureRandom.hex(16)
        post events_path(@connection), params: first, headers: signed_headers(@connection, first, nonce: nonce)
        assert_response :no_content

        second = JSON.generate(message_event("m2"))
        assert_nothing_written do
          post events_path(@connection), params: second, headers: signed_headers(@connection, second, nonce: nonce)
        end
        assert_response :unauthorized
        assert_equal "replayed_nonce", response.parsed_body["error"]
      end

      test "the same nonce is still usable on another connection" do
        nonce = SecureRandom.hex(16)
        body = JSON.generate(message_event("m1"))
        post events_path(@connection), params: body, headers: signed_headers(@connection, body, nonce: nonce)
        post events_path(@other), params: body, headers: signed_headers(@other, body, nonce: nonce)
        assert_response :no_content
      end

      test "events for a disconnected connection are refused" do
        secret = secret_for(@connection)
        @connection.disconnect!
        body = JSON.generate(message_event("m1"))
        headers = CommsSignature.headers_for(
          secret: secret, connection_id: @connection.public_id, method: "POST", path: events_path(@connection), body: body
        ).merge("Content-Type" => "application/json")

        assert_nothing_written do
          post events_path(@connection), params: body, headers: headers
        end
        assert_response :unauthorized
        assert_equal "revoked", @connection.reload.status
      end

      test "events for a connection that is not accepting them are refused and consume no nonce" do
        @connection.update!(status: "suspended")

        assert_nothing_written do
          post_event @connection, message_event("m1")
          assert_response :conflict
          post_event @connection, { type: "status.changed", status: "connected" }
          assert_response :conflict
        end
        assert_equal 0, @connection.comms_request_nonces.count
      end

      test "message events need a connected connection" do
        @connection.update!(status: "pairing")

        assert_nothing_written do
          post_event @connection, message_event("m1")
        end
        assert_response :conflict
      end

      test "an oversized batch is refused" do
        ids = (1..(CommsEvents::MAX_BATCH + 1)).map { |n| "m#{n}" }
        assert_nothing_written do
          post_event @connection, message_event(*ids)
        end
        assert_response :content_too_large
      end

      test "a non-comms connection cannot be written" do
        oura = @account.service_connections.create!(
          connected_by_user: @user, provider: "oura", external_subject_id: "oura-1", management_scope: "personal",
          credential_kind: "oauth2", credential_payload_hash: { "callback_secret" => "x" * 64 },
          credential_metadata: { "credential_strategy" => "refresh_broker" }
        )
        body = JSON.generate(message_event("m1"))
        post events_path(oura), params: body, headers: signed_headers(oura, body)
        assert_response :unauthorized
        assert_equal "unknown_connection", response.parsed_body["error"]
      end

      test "pairing QR is stored encrypted and cleared when pairing completes" do
        @connection.update!(status: "pairing")
        post_event @connection, { type: "pairing.qr", code: "2@QRCANARY", issued_at: Time.current.utc.iso8601, expires_at: 40.seconds.from_now.utc.iso8601 }
        assert_response :no_content
        @connection.reload
        assert_equal "2@QRCANARY", @connection.current_pairing_qr[:code]
        assert_not_includes raw_column(ServiceConnection, @connection.id, "pairing_qr"), "QRCANARY"

        post_event @connection, { type: "status.changed", status: "connected" }
        assert_response :no_content
        @connection.reload
        assert_equal "connected", @connection.status
        assert_nil @connection.pairing_qr
        assert_nil @connection.pairing_qr_expires_at
      end

      test "a QR is refused once connected, and when already expired" do
        post_event @connection, { type: "pairing.qr", code: "late", issued_at: Time.current.utc.iso8601, expires_at: 30.seconds.from_now.utc.iso8601 }
        assert_response :conflict

        @connection.update!(status: "pairing")
        post_event @connection, { type: "pairing.qr", code: "old", issued_at: 30.seconds.ago.utc.iso8601, expires_at: 1.second.ago.utc.iso8601 }
        assert_response :unprocessable_entity
        assert_nil @connection.reload.pairing_qr
      end

      test "a delayed older QR cannot overwrite its replacement" do
        @connection.update!(status: "pairing")
        older_issued = 20.seconds.ago.utc.iso8601
        post_event @connection, { type: "pairing.qr", code: "B-newer", issued_at: Time.current.utc.iso8601, expires_at: 20.seconds.from_now.utc.iso8601 }
        assert_response :no_content
        assert_no_difference -> { CommsRequestNonce.count } do
          post_event @connection, { type: "pairing.qr", code: "A-older", issued_at: older_issued, expires_at: 40.seconds.from_now.utc.iso8601 }
        end
        assert_response :conflict
        assert_equal "stale_qr", response.parsed_body["error"]
        assert_equal "B-newer", @connection.reload.current_pairing_qr[:code]
      end

      test "messages are immutable once stored: a reordered retry cannot restore or replace content" do
        first = message_event("m1")
        post_event @connection, first
        assert_response :no_content
        edited = message_event("m1")
        edited[:messages][0][:body] = "edited B"
        post_event @connection, edited
        assert_response :no_content
        assert_equal "hello m1", @connection.comms_messages.find_by!(provider_message_id: "m1").body
        post_event @connection, first
        assert_response :no_content
        assert_equal "hello m1", @connection.comms_messages.find_by!(provider_message_id: "m1").body
        assert_equal 1, @connection.comms_messages.where(provider_message_id: "m1").count
      end

      test "an oversized body is refused before it is parsed" do
        body = JSON.generate({ type: "message.upsert", messages: [ { body: "x" * (CommsSignature::MAX_BODY_BYTES + 10) } ] })
        headers = signed_headers(@connection, body)
        JSON.stub(:parse, ->(*) { flunk "body was parsed" }) do
          post events_path(@connection), params: body, headers: headers
        end
        assert_response :content_too_large
      end

      test "a phone-side logout needs the owner to pair again" do
        post_event @connection, { type: "status.changed", status: "logged_out" }
        assert_response :no_content
        assert_equal "reauthorizing", @connection.reload.status
      end

      test "message content does not reach the log" do
        canary = "CANARY-#{SecureRandom.hex(8)}"
        output = StringIO.new
        capture = ActiveSupport::Logger.new(output)
        capture.level = :debug
        Rails.logger.broadcast_to(capture)
        begin
          post_event @connection, {
            type: "message.upsert",
            messages: [ {
              provider_message_id: "m-canary", chat: "c-canary@s.whatsapp.net", sent_at: "2026-10-09T10:00:00Z",
              sender_id: "#{canary}-sender-id", sender_name: "#{canary}-sender", body: "#{canary}-body", caption: "#{canary}-caption"
            } ]
          }
          post_event @connection, { type: "chat.upsert", chats: [ { provider_chat_id: "c-canary@s.whatsapp.net", name: "#{canary}-name" } ] }
          @connection.update!(status: "pairing")
          post_event @connection, { type: "pairing.qr", code: "#{canary}-qr", issued_at: Time.current.utc.iso8601, expires_at: 30.seconds.from_now.utc.iso8601 }
        ensure
          Rails.logger.stop_broadcasting_to(capture)
        end
        assert_response :no_content

        logged = output.string
        assert_includes logged, "Internal::Comms::EventsController#create"
        assert_not_includes logged, canary
        assert_not_includes File.read(Rails.root.join("log/test.log")), canary
      end

      test "message bodies, names and senders are not plaintext in the database" do
        post_event @connection, message_event("m1")
        post_event @connection, { type: "chat.upsert", chats: [ { provider_chat_id: "447700900123@s.whatsapp.net", name: "Secret Chat Name" } ] }

        message = @connection.comms_messages.sole
        { "body" => "hello m1", "sender_name" => "Alice", "sender_id" => "447700900999@s.whatsapp.net" }.each do |column, plaintext|
          assert_not_includes raw_column(CommsMessage, message.id, column), plaintext
        end
        chat = @connection.comms_chats.sole
        assert_not_includes raw_column(CommsChat, chat.id, "name"), "Secret Chat Name"
        assert_equal "Secret Chat Name", chat.reload.name
      end

      private

      def whatsapp_connection(status:)
        attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @user)
        @account.service_connections.create!(
          connected_by_user: @user, provider: "whatsapp", management_scope: "personal", status: status,
          **attributes.slice(:label, :credential_kind, :credential_fingerprint, :credential_metadata).merge(credential_payload_hash: attributes[:credential_payload])
        )
      end

      def secret_for(connection)
        connection.credential_payload_hash.fetch("callback_secret")
      end

      def events_path(connection)
        internal_comms_connection_events_path(connection.public_id)
      end

      def signed_headers(connection, body, path: events_path(connection), now: Time.current, nonce: SecureRandom.hex(16))
        CommsSignature.headers_for(
          secret: secret_for(connection), connection_id: connection.public_id,
          method: "POST", path: path, body: body, now: now, nonce: nonce
        ).merge("Content-Type" => "application/json")
      end

      def post_event(connection, event)
        body = JSON.generate(event)
        post events_path(connection), params: body, headers: signed_headers(connection, body)
      end

      def message_event(*ids)
        {
          type: "message.upsert",
          messages: ids.each_with_index.map do |id, index|
            {
              provider_message_id: id, chat: "447700900123@s.whatsapp.net",
              sender_id: "447700900999@s.whatsapp.net", sender_name: "Alice",
              sent_at: Time.iso8601("2026-10-09T10:00:00Z").advance(minutes: index).utc.iso8601,
              body: "hello #{id}", media_kind: nil, caption: nil
            }
          end
        }
      end

      def assert_nothing_written(&block)
        assert_no_difference %w[CommsMessage.count CommsChat.count CommsRequestNonce.count], &block
      end

      def raw_column(model, id, column)
        model.connection.select_value("SELECT #{column} FROM #{model.table_name} WHERE id = #{id.to_i}").to_s
      end

    end
  end
end
