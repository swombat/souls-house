require "test_helper"

module Api
  module V1
    class CommsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @agent = agents(:research_assistant)
        @user = users(:user_1)
        @api_key = ApiKey.generate_for(@user, name: "Comms reader", agent: @agent)
        @connection = whatsapp_connection(@agent.account)
        @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
        @chat = @connection.comms_chats.create!(provider_chat_id: "447700900123@s.whatsapp.net", name: "Alice", kind: "direct",
                                               last_activity_at: Time.iso8601("2026-10-09T10:02:00Z"))
        @quiet = @connection.comms_chats.create!(provider_chat_id: "g1@g.us", name: "Family", kind: "group",
                                                last_activity_at: Time.iso8601("2026-10-01T10:00:00Z"))
        3.times do |index|
          @connection.comms_messages.create!(comms_chat: @chat, provider_message_id: "m#{index}", sender_name: "Alice",
                                             sent_at: Time.iso8601("2026-10-09T10:00:00Z").advance(minutes: index), body: "hello #{index}")
        end
      end

      test "an enabled resident reads chats, most recent first, without caching" do
        get api_v1_service_connection_comms_chats_url(@connection.public_id), headers: auth

        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_equal [ @chat.provider_chat_id, @quiet.provider_chat_id ], response.parsed_body["chats"].map { |chat| chat["provider_chat_id"] }
        assert_equal "Alice", response.parsed_body["chats"].first["name"]
      end

      test "an enabled resident reads messages oldest first, by provider id or public id" do
        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.provider_chat_id), headers: auth
        assert_response :ok
        assert_equal "no-store", response.headers["Cache-Control"]
        assert_equal %w[m0 m1 m2], response.parsed_body["messages"].map { |message| message["provider_message_id"] }
        assert_equal "hello 0", response.parsed_body["messages"].first["body"]

        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.public_id, limit: 2), headers: auth
        assert_equal %w[m1 m2], response.parsed_body["messages"].map { |message| message["provider_message_id"] }

        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.public_id, since: "2026-10-09T10:01:00Z", limit: 1),
            headers: auth
        assert_equal %w[m1], response.parsed_body["messages"].map { |message| message["provider_message_id"] }
      end

      test "the next_cursor pages through many messages in one second without skipping or repeating" do
        second = Time.iso8601("2026-10-09T11:00:00Z")
        5.times { |n| @connection.comms_messages.create!(comms_chat: @chat, provider_message_id: "s#{n}", sent_at: second, body: "same #{n}") }
        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.public_id, since: second.iso8601, limit: 2), headers: auth
        seen = response.parsed_body["messages"].map { |message| message["provider_message_id"] }
        cursor = response.parsed_body["next_cursor"]
        pages = 1
        while cursor
          get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.public_id, after: cursor, limit: 2), headers: auth
          assert_response :ok
          seen.concat(response.parsed_body["messages"].map { |message| message["provider_message_id"] })
          cursor = response.parsed_body["next_cursor"]
          pages += 1
          assert pages < 10, "pagination did not terminate"
        end
        assert_equal %w[s0 s1 s2 s3 s4], seen
      end

      test "a malformed cursor is a bad request" do
        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.public_id, after: "not-a-cursor"), headers: auth
        assert_response :bad_request
      end

      test "since is inclusive, so messages sharing the boundary second are not skipped" do
        @chat.comms_messages.create!(service_connection: @connection, provider_message_id: "m1b",
                                     sent_at: Time.iso8601("2026-10-09T10:01:00Z"), body: "same second")
        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.public_id, since: "2026-10-09T10:01:00Z", limit: 10),
            headers: auth
        ids = response.parsed_body["messages"].map { |message| message["provider_message_id"] }
        assert_includes ids, "m1"
        assert_includes ids, "m1b"
      end

      test "the limit is bounded" do
        now = Time.current
        CommsChat.insert_all!((1..205).map do |n|
          { service_connection_id: @connection.id, provider_chat_id: "bulk-#{n}", created_at: now, updated_at: now }
        end)

        get api_v1_service_connection_comms_chats_url(@connection.public_id, limit: 10_000), headers: auth
        assert_response :ok
        assert_equal 200, response.parsed_body["chats"].size
      end

      test "a resident without an access row gets 404" do
        @access.destroy!
        assert_not_found_everywhere
      end

      test "a resident with a disabled access row gets 404" do
        @access.update!(enabled: false)
        assert_not_found_everywhere
      end

      test "another connection's id gets 404" do
        other = whatsapp_connection(@agent.account)
        other.comms_chats.create!(provider_chat_id: "x@s.whatsapp.net")

        get api_v1_service_connection_comms_chats_url(other.public_id), headers: auth
        assert_response :not_found
        get api_v1_service_connection_comms_messages_url(other.public_id, chat: "x@s.whatsapp.net"), headers: auth
        assert_response :not_found
      end

      test "another connection's chat is not readable through this connection" do
        other = whatsapp_connection(@agent.account)
        foreign = other.comms_chats.create!(provider_chat_id: "x@s.whatsapp.net")

        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: foreign.public_id), headers: auth
        assert_response :not_found
      end

      test "another account's connection gets 404" do
        foreign_agent = agents(:other_account_agent)
        foreign = whatsapp_connection(foreign_agent.account)
        foreign_agent.agent_service_accesses.create!(service_connection: foreign, enabled: true)

        get api_v1_service_connection_comms_chats_url(foreign.public_id), headers: auth
        assert_response :not_found
      end

      test "a connection that is not connected gets the token broker's 409" do
        @connection.update!(status: "pairing")

        get api_v1_service_connection_comms_chats_url(@connection.public_id), headers: auth
        assert_response :conflict
        assert_equal "This service connection is not currently connected", response.parsed_body["error"]
      end

      test "a person's key is not a resident key" do
        person_key = ApiKey.generate_for(@user, name: "Person")
        get api_v1_service_connection_comms_chats_url(@connection.public_id), headers: { "Authorization" => "Bearer #{person_key.raw_token}" }
        assert_response :forbidden
      end

      private

      def auth
        { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

      def assert_not_found_everywhere
        get api_v1_service_connection_comms_chats_url(@connection.public_id), headers: auth
        assert_response :not_found
        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.provider_chat_id), headers: auth
        assert_response :not_found
      end

      def whatsapp_connection(account)
        attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @user)
        account.service_connections.create!(
          connected_by_user: @user, provider: "whatsapp", management_scope: "personal", status: "connected",
          label: attributes[:label], credential_kind: attributes[:credential_kind],
          credential_fingerprint: attributes[:credential_fingerprint], credential_metadata: attributes[:credential_metadata],
          credential_payload_hash: attributes[:credential_payload]
        )
      end

    end
  end
end
