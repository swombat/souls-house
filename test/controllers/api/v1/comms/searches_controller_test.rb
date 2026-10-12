require "test_helper"
require "support/telegram_comms_helpers"

module Api
  module V1
    module Comms
      # Residents' bounded Telegram search, and the read endpoints for
      # Telegram's tombstones and sync state.
      class SearchesControllerTest < ActionDispatch::IntegrationTest

        include TelegramCommsHelpers

        setup do
          @agent = agents(:research_assistant)
          @user = users(:user_1)
          @headers = { "Authorization" => "Bearer #{ApiKey.generate_for(@user, name: "Telegram tests", agent: @agent).raw_token}" }
          @connection = telegram_connection(account: @agent.account, user: @user)
          @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
          @synced = @connection.comms_chats.create!(provider_chat_id: "user:1", kind: "direct", sync_state: { "synced" => true })
          @unsynced = @connection.comms_chats.create!(provider_chat_id: "channel:5", kind: "channel",
                                                      sync_state: { "synced" => false, "reason" => "broadcast_channel" })
        end

        test "a granted resident searches the synced scope through the connector" do
          reply = { coverage: { scope: "synced", chats: 12 }, results: [ { chat: "user:1", provider_message_id: "9", body: "lunch?" } ] }
          with_telegram_connector(replies: { "search" => reply }) do |requests|
            get search_path, params: { query: "lunch", limit: 5 }, headers: @headers
            assert_response :ok
            body = JSON.parse(requests.sole.body)
            assert_equal [ "lunch", "synced", 5, nil ], body.values_at("query", "scope", "limit", "chat")
          end
          assert_equal "synced", response.parsed_body["scope"]
          assert_equal "lunch?", response.parsed_body.dig("results", 0, "body")
          assert_equal 12, response.parsed_body.dig("coverage", "chats")
        end

        test "searching one chat sends its typed peer" do
          with_telegram_connector(replies: { "search" => { results: [] } }) do |requests|
            get search_path, params: { query: "x", chat: @synced.public_id }, headers: @headers
            assert_equal "user:1", JSON.parse(requests.sole.body)["chat"]
          end
        end

        test "beyond the synced scope needs the owner's switch, and an unsynced chat needs that scope" do
          with_telegram_connector do |requests|
            get search_path, params: { query: "x", scope: "all_dialogs" }, headers: @headers
            assert_response :forbidden
            get search_path, params: { query: "x", chat: @unsynced.public_id }, headers: @headers
            assert_response :forbidden
            assert_empty requests
          end

          @connection.update!(credential_metadata: @connection.credential_metadata.merge("search_all_dialogs" => true))
          with_telegram_connector(replies: { "search" => { results: [] } }) do |requests|
            get search_path, params: { query: "x", chat: @unsynced.public_id, scope: "all_dialogs" }, headers: @headers
            assert_response :ok
            assert_equal "all_dialogs", JSON.parse(requests.sole.body)["scope"]
          end
        end

        test "a revoked grant, another account's connection, or a disconnected connection are refused" do
          @access.update!(enabled: false)
          with_telegram_connector do |requests|
            get search_path, params: { query: "x" }, headers: @headers
            assert_response :not_found
            assert_empty requests
          end

          @access.update!(enabled: true)
          @connection.update!(status: "reauthorizing")
          get search_path, params: { query: "x" }, headers: @headers
          assert_response :conflict

          other = telegram_connection(account: accounts(:team), user: users(:admin))
          get api_v1_service_connection_comms_search_path(other.public_id), params: { query: "x" }, headers: @headers
          assert_response :not_found
        end

        test "bad queries are refused before reaching the connector" do
          with_telegram_connector do |requests|
            get search_path, params: { query: "" }, headers: @headers
            assert_response :bad_request
            get search_path, params: { query: "a" * 201 }, headers: @headers
            assert_response :bad_request
            get search_path, params: { query: "x", scope: "everything" }, headers: @headers
            assert_response :bad_request
            assert_empty requests
          end
        end

        test "a busy or unreachable connector is reported as unavailable" do
          with_telegram_connector(replies: { "search" => [ 503, { error: "busy" } ] }) do
            get search_path, params: { query: "x" }, headers: @headers
          end
          assert_response :service_unavailable

          with_telegram_connector(replies: { "search" => Errno::ECONNREFUSED }) do
            get search_path, params: { query: "x" }, headers: @headers
          end
          assert_response :service_unavailable
        end

        test "plain http to the connector is refused" do
          with_telegram_connector(url: "http://comms.internal:8080") do |requests|
            get search_path, params: { query: "x" }, headers: @headers
            assert_response :service_unavailable
            assert_empty requests
          end
        end

        test "messages show tombstones without content and chats show their sync state" do
          @synced.comms_messages.create!(service_connection: @connection, provider_message_id: "1", sent_at: 1.hour.ago, body: "kept")
          @synced.comms_messages.create!(service_connection: @connection, provider_message_id: "2", sent_at: 30.minutes.ago,
                                         body: nil, deleted_at: 10.minutes.ago)

          get api_v1_service_connection_comms_messages_path(@connection.public_id), params: { chat: "user:1" }, headers: @headers
          messages = response.parsed_body["messages"]
          assert_equal [ "kept", nil ], messages.map { |message| message["body"] }
          assert_equal [ nil, true ], messages.map { |message| message["deleted"] }

          get api_v1_service_connection_comms_chats_path(@connection.public_id), headers: @headers
          channel = response.parsed_body["chats"].find { |chat| chat["provider_chat_id"] == "channel:5" }
          assert_equal({ "synced" => false, "reason" => "broadcast_channel" }, channel["sync_state"])
        end

        test "WhatsApp connections have no search" do
          attributes = Services::Definition.fetch("whatsapp").adapter.connection_attributes(credentials: {}, user: @user)
          whatsapp = @agent.account.service_connections.create!(
            connected_by_user: @user, provider: "whatsapp", management_scope: "personal", status: "connected",
            **attributes.slice(:label, :credential_kind, :credential_fingerprint, :credential_metadata)
              .merge(credential_payload_hash: attributes[:credential_payload])
          )
          @agent.agent_service_accesses.create!(service_connection: whatsapp, enabled: true)
          get api_v1_service_connection_comms_search_path(whatsapp.public_id), params: { query: "x" }, headers: @headers
          assert_response :unprocessable_entity
        end

        private

        def search_path
          api_v1_service_connection_comms_search_path(@connection.public_id)
        end

      end
    end
  end
end
