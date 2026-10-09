require "test_helper"
require "support/comms_send_helpers"

module Api
  module V1
    # POST /api/v1/service_connections/:id/comms/messages (spec §5): read
    # scope, then can_send, then a claimed record, then the connector.
    class CommsSendControllerTest < ActionDispatch::IntegrationTest

      include CommsSendHelpers

      setup do
        setup_comms_send
        @api_key = ApiKey.generate_for(@owner, name: "Comms sender", agent: @agent)
      end

      test "a resident with read but not send gets 403, no record and no connector call" do
        calls = with_fake_connector do
          assert_no_difference -> { CommsSend.count } do
            send_text
          end
        end
        assert_response :forbidden
        assert_equal "send_not_granted", response.parsed_body["error"]
        assert_empty calls
      end

      test "a granted resident sends: the record is written, the connector called once, the outcome stored" do
        grant_send!
        seen_status = nil
        calls = with_fake_connector(->(send) { seen_status = CommsSend.find(send.id).status; sent_outcome(send) }) do
          assert_difference -> { CommsSend.count }, 1 do
            send_text(text: "On my way")
          end
        end

        assert_response :created
        assert_equal "no-store", response.headers["Cache-Control"]
        send = CommsSend.last
        assert_equal [ send.id ], calls
        assert_equal "unknown", seen_status, "the record exists, marked dispatched, before the connector is called"
        assert_equal [ "sent", @agent.id, @chat.id, "On my way" ], [ send.status, send.agent_id, send.comms_chat_id, send.text ]
        assert_equal send.public_id, response.parsed_body.dig("send", "id")
        assert_equal "sent", response.parsed_body.dig("send", "status")
        assert_match(/\A3EB0[0-9A-F]{20}\z/, send.provider_message_id)
        assert send.sent_at
      end

      test "the chat may be named by its public id" do
        grant_send!
        with_fake_connector { send_text(chat: @chat.public_id) }
        assert_response :created
      end

      test "a chat not on this connection is 404 with no record" do
        grant_send!
        other = build_whatsapp_connection(@account, @owner)
        foreign = other.comms_chats.create!(provider_chat_id: "447700900999@s.whatsapp.net")

        calls = with_fake_connector do
          assert_no_difference -> { CommsSend.count } do
            send_text(chat: foreign.public_id)
            assert_response :not_found
            send_text(chat: foreign.provider_chat_id)
            assert_response :not_found
            send_text(chat: "447700900000@s.whatsapp.net")
            assert_response :not_found
          end
        end
        assert_empty calls
      end

      test "a repeated client_request_id sends once and returns the original record" do
        grant_send!
        calls = with_fake_connector do
          send_text(client_request_id: "retry-1")
          assert_response :created
          first = response.parsed_body["send"]
          send_text(client_request_id: "retry-1")
          assert_response :ok
          assert_equal first, response.parsed_body["send"]
        end
        assert_equal 1, calls.size
        assert_equal 1, CommsSend.count
      end

      test "the same client_request_id with different text or chat is 409" do
        grant_send!
        other_chat = @connection.comms_chats.create!(provider_chat_id: "g1@g.us", kind: "group")
        calls = with_fake_connector do
          send_text(client_request_id: "retry-2", text: "first")
          send_text(client_request_id: "retry-2", text: "second")
          assert_response :conflict
          assert_equal "client_request_id_reused", response.parsed_body["error"]
          send_text(client_request_id: "retry-2", text: "first", chat: other_chat.provider_chat_id)
          assert_response :conflict
        end
        assert_equal 1, calls.size
        assert_equal [ "first" ], CommsSend.all.map(&:text)
      end

      test "the same client_request_id from another resident is a separate send" do
        grant_send!
        other_agent = @account.agents.create!(name: "Second Sender", model_id: "openrouter/auto", runtime: "external")
        other_access = other_agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
        grant_send!(other_access)
        other_key = ApiKey.generate_for(@owner, name: "Second sender", agent: other_agent)

        calls = with_fake_connector do
          send_text(client_request_id: "shared")
          post api_v1_service_connection_comms_messages_url(@connection.public_id),
               params: { chat: @chat.provider_chat_id, text: "hello", client_request_id: "shared" }, as: :json,
               headers: { "Authorization" => "Bearer #{other_key.raw_token}" }
          assert_response :created
        end
        assert_equal 2, calls.size
        assert_equal [ @agent.id, other_agent.id ].sort, CommsSend.pluck(:agent_id).sort
      end

      test "a connector timeout leaves the send unknown, and nothing retries it" do
        grant_send!
        timeout = ->(_send) { raise Net::ReadTimeout }
        calls = nil
        Net::HTTP.stub(:start, ->(*_args, **_options, &_block) { raise Net::ReadTimeout }) do
          with_connector_url do
            send_text(client_request_id: "slow")
          end
        end
        assert_response :created
        send = CommsSend.last
        assert_equal [ "unknown", "connector_timeout" ], [ send.status, send.error_code ]
        assert_nil send.sent_at

        # A retry with the same id returns the unknown record and does not call again.
        calls = with_fake_connector(timeout) { send_text(client_request_id: "slow") }
        assert_response :ok
        assert_equal "unknown", response.parsed_body.dig("send", "status")
        assert_empty calls
      end

      test "a connector that says failed records failed with its code; anything unclear is unknown" do
        grant_send!
        with_fake_connector(->(_send) { CommsConnector::SendOutcome.new(status: "failed", provider_message_id: nil, sent_at: nil, error_code: "not_on_whatsapp") }) do
          send_text(client_request_id: "f1")
        end
        assert_equal [ "failed", "not_on_whatsapp" ], CommsSend.last.values_at(:status, :error_code)

        # The connector restarted between attempt and outcome and reports unknown.
        with_fake_connector(->(_send) { CommsConnector::SendOutcome.new(status: "unknown", provider_message_id: nil, sent_at: nil, error_code: "attempted_before_restart") }) do
          send_text(client_request_id: "f2")
        end
        assert_equal [ "unknown", "attempted_before_restart" ], CommsSend.last.values_at(:status, :error_code)
      end

      test "text is bounded and required" do
        grant_send!
        calls = with_fake_connector do
          assert_no_difference -> { CommsSend.count } do
            send_text(text: "x" * (CommsSend::MAX_TEXT_LENGTH + 1))
            assert_response :unprocessable_entity
            send_text(text: "   ")
            assert_response :unprocessable_entity
            send_text(client_request_id: "")
            assert_response :unprocessable_entity
          end
          send_text(text: "x" * CommsSend::MAX_TEXT_LENGTH)
          assert_response :created
        end
        assert_equal 1, calls.size
      end

      test "the rate limit is per connection and refuses with 429 and no record" do
        grant_send!
        calls = with_fake_connector do
          CommsSending::PER_MINUTE.times { |n| send_text(client_request_id: "r#{n}") }
          assert_no_difference -> { CommsSend.count } do
            send_text(client_request_id: "over")
          end
          assert_response :too_many_requests
          assert_equal "rate_limited", response.parsed_body["error"]

          # A retry of an existing send is not a new send: it is not refused.
          send_text(client_request_id: "r0")
          assert_response :ok
        end
        assert_equal CommsSending::PER_MINUTE, calls.size

        travel 2.minutes do
          with_fake_connector { send_text(client_request_id: "later") }
          assert_response :created
        end
      end

      test "the daily cap counts the last day of sends" do
        grant_send!
        now = Time.current
        CommsSend.insert_all!((1..CommsSending::PER_DAY).map do |n|
          { service_connection_id: @connection.id, agent_id: @agent.id, comms_chat_id: @chat.id, text: "old #{n}",
            client_request_id: "day-#{n}", status: "sent", requested_at: now - 2.hours, created_at: now, updated_at: now }
        end)
        calls = with_fake_connector { send_text(client_request_id: "one-too-many") }
        assert_response :too_many_requests
        assert_empty calls
      end

      test "disabling the access row ends sending (404, as for reads)" do
        grant_send!
        @agent.set_service_access!(@connection, enabled: false, actor: @owner)
        calls = with_fake_connector { send_text }
        assert_response :not_found
        assert_empty calls
      end

      test "a connection that is not connected cannot send" do
        grant_send!
        @connection.update_columns(status: "pairing")
        calls = with_fake_connector { send_text }
        assert_response :conflict
        assert_empty calls
      end

      test "no text appears in the logs" do
        grant_send!
        canary = "canary-#{SecureRandom.hex(8)}"
        log = StringIO.new
        logger = ActiveSupport::Logger.new(log)
        logger.level = :debug
        original = Rails.logger
        ActiveRecord::Base.logger = logger
        Rails.logger = logger
        ActionController::Base.logger = logger
        ActionController::API.logger = logger
        begin
          with_fake_connector { send_text(text: "secret #{canary}", client_request_id: "log-1") }
          with_fake_connector { send_text(text: "secret #{canary}", client_request_id: "log-1") }
          get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.provider_chat_id), headers: auth
        ensure
          Rails.logger = original
          ActiveRecord::Base.logger = original
          ActionController::Base.logger = original
          ActionController::API.logger = original
        end
        assert_response :ok
        assert_match "comms/messages", log.string, "the request was logged"
        assert_no_match canary, log.string
      end

      private

      def auth
        { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

      def send_text(chat: @chat.provider_chat_id, text: "hello", client_request_id: "req-#{SecureRandom.hex(4)}")
        post api_v1_service_connection_comms_messages_url(@connection.public_id),
             params: { chat: chat, text: text, client_request_id: client_request_id }, as: :json, headers: auth
      end

      def with_connector_url
        previous = ENV["COMMS_CONNECTOR_URL"]
        ENV["COMMS_CONNECTOR_URL"] = "http://comms.internal:8080"
        yield
      ensure
        ENV["COMMS_CONNECTOR_URL"] = previous
      end

    end
  end
end
