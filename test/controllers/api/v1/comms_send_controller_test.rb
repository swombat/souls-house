require "test_helper"
require "support/comms_send_helpers"
require "support/whatsapp_comms_helpers"

module Api
  module V1
    # POST /api/v1/service_connections/:id/comms/messages (WhatsApp spec
    # §5): read scope, then the gate, then can_send, then a claimed record,
    # then the connector. Every refusal creates nothing and calls nothing.
    class CommsSendControllerTest < ActionDispatch::IntegrationTest

      include CommsSendHelpers
      include WhatsappCommsHelpers

      setup do
        setup_comms_send
        @api_key = ApiKey.generate_for(@owner, name: "Comms sender", agent: @agent)
      end

      teardown { teardown_comms_send }

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

      test "with sending unavailable for the provider the endpoint is 404, even for a granted resident" do
        grant_send!
        without_sending do
          calls = with_fake_connector do
            assert_no_difference -> { CommsSend.count } do
              send_text
            end
          end
          assert_response :not_found
          assert_empty calls
        end
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
        assert_match Services::WhatsappAdapter::SEND_MESSAGE_ID_FORMAT, send.provider_message_id
        assert send.sent_at
      end

      test "end to end through the signed command: the fake connector's 200 makes it sent" do
        grant_send!
        with_whatsapp_connector(stub_http: false) do
          fake = Object.new
          seen = []
          fake.define_singleton_method(:request) do |request|
            seen << request
            body = JSON.parse(request.body)
            Net::HTTPOK.new("1.1", "200", "").tap do |response|
              response.instance_variable_set(:@read, true)
              response.instance_variable_set(:@body, JSON.generate(status: "sent", message_id: body["message_id"], sent_at: "2026-10-24T10:00:00Z"))
            end
          end
          Net::HTTP.stub(:start, ->(_host, _port, **_options, &block) { block.call(fake) }) { send_text(client_request_id: "e2e") }
          assert_response :created
          assert_equal "sent", response.parsed_body.dig("send", "status")
          assert_equal 1, seen.size
          assert_equal "/connections/#{@connection.public_id}/send_text", seen.first.path
        end
      end

      test "the chat may be named by its public id" do
        grant_send!
        with_fake_connector { send_text(chat: @chat.public_id) }
        assert_response :created
      end

      test "only existing chats on this connection, one chat per request" do
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
            send_text(chat: [ @chat.provider_chat_id, "447700900000@s.whatsapp.net" ])
            assert_response :unprocessable_entity
            assert_equal "invalid_chat", response.parsed_body["error"]
          end
        end
        assert_empty calls
        assert_nil @connection.comms_chats.find_by(provider_chat_id: "447700900000@s.whatsapp.net"), "no chat is created by sending"
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
        with_whatsapp_connector(stub_http: false) do
          Net::HTTP.stub(:start, ->(*_args, **_options, &_block) { raise Net::ReadTimeout }) do
            send_text(client_request_id: "slow")
          end
        end
        assert_response :created
        send = CommsSend.last
        assert_equal [ "unknown", "connector_timeout" ], [ send.status, send.error_code ]
        assert_nil send.sent_at

        calls = with_fake_connector { send_text(client_request_id: "slow") }
        assert_response :ok
        assert_equal "unknown", response.parsed_body.dig("send", "status")
        assert_empty calls
      end

      test "text only, bounded and required" do
        grant_send!
        calls = with_fake_connector do
          assert_no_difference -> { CommsSend.count } do
            send_text(text: "x" * (CommsSend::MAX_TEXT_LENGTH + 1))
            assert_response :unprocessable_entity
            send_text(text: "😀" * CommsSend::MAX_TEXT_LENGTH)
            assert_response :unprocessable_entity
            send_text(text: "   ")
            assert_response :unprocessable_entity
            send_text(text: { "image" => "x" })
            assert_response :unprocessable_entity
            send_text(client_request_id: "")
            assert_response :unprocessable_entity
          end
          send_text(text: "x" * CommsSend::MAX_TEXT_LENGTH)
          assert_response :created
        end
        assert_equal 1, calls.size
      end

      test "pacing is per connection and refuses a new send with 429 and no record" do
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

      test "disabling the access row ends sending (404, as for reads)" do
        grant_send!
        @agent.set_service_access!(@connection, enabled: false, actor: @owner)
        calls = with_fake_connector { send_text }
        assert_response :not_found
        assert_empty calls
        assert_equal 0, CommsSend.count
      end

      test "a connection that is not connected cannot send (409, as for reads)" do
        grant_send!
        @connection.update_columns(status: "pairing")
        calls = with_fake_connector { send_text }
        assert_response :conflict
        assert_empty calls
        assert_equal 0, CommsSend.count
      end

      test "reading shows which resident sent a linked message" do
        grant_send!
        with_fake_connector { send_text(client_request_id: "shown") }
        send = CommsSend.last
        CommsEvents.receive!(@connection.reload, { "type" => "message.upsert", "attempt" => @connection.pairing_attempt, "messages" => [
          { "provider_message_id" => send.provider_message_id, "chat" => @chat.provider_chat_id, "sender_id" => "447700900001@s.whatsapp.net",
            "sent_at" => "2026-10-24T12:00:00Z", "body" => "hello" }
        ] }, nonce: SecureRandom.hex(16))
        get api_v1_service_connection_comms_messages_url(@connection.public_id, chat: @chat.provider_chat_id), headers: auth
        assert_response :ok
        message = response.parsed_body["messages"].sole
        assert_equal({ "resident_id" => @agent.to_param, "resident_name" => "Comms Sender", "send_id" => send.public_id }, message["sent_by"])
      end

      test "neither the text nor the chat appears in the logs" do
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
        ensure
          Rails.logger = original
          ActiveRecord::Base.logger = original
          ActionController::Base.logger = original
          ActionController::API.logger = original
        end
        assert_response :ok
        assert_match "comms/messages", log.string, "the request was logged"
        assert_no_match canary, log.string
        assert_no_match "447700900123", log.string
      end

      private

      def auth
        { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

      def send_text(chat: @chat.provider_chat_id, text: "hello", client_request_id: "req-#{SecureRandom.hex(4)}")
        post api_v1_service_connection_comms_messages_url(@connection.public_id),
             params: { chat: chat, text: text, client_request_id: client_request_id }, as: :json, headers: auth
      end

    end
  end
end
