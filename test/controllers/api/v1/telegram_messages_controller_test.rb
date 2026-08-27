require "test_helper"
require "ostruct"

module Api
  module V1
    class TelegramMessagesControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @agent.update!(telegram_bot_token: "123:ABC", telegram_bot_username: "test_bot")
        @api_key = ApiKey.generate_for(@user, name: "Agent Telegram", agent: @agent)
        @token = @api_key.raw_token
        @subscriber = users(:user_1)
        @subscriber.profile.update!(first_name: "Daniel", last_name: "Tester")
        @subscription = @agent.telegram_subscriptions.create!(user: @subscriber, telegram_chat_id: 111)
      end

      test "agent-scoped key sends telegram message to matching subscriber" do
        posts = []
        fake_ok = OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 77, "date" => Time.current.to_i } }.to_json)

        Net::HTTP.stub :post, ->(uri, body, headers) { posts << [ uri, JSON.parse(body), headers ]; fake_ok } do
          post api_v1_telegram_messages_url,
            params: { recipient: "daniel", text: "Hello <friend>" },
            headers: { "Authorization" => "Bearer #{@token}" }
        end

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal [ @subscriber.email_address ], json["delivered"].map { |recipient| recipient["email"] }
        assert_empty json["blocked"]
        assert_empty json["failures"]
        assert_equal 1, posts.length
        assert_equal "https://api.telegram.org/bot#{@agent.telegram_bot_token}/sendMessage", posts.first[0].to_s
        assert_equal 111, posts.first[1]["chat_id"]
        assert_equal "Hello &lt;friend&gt;", posts.first[1]["text"]
        telegram_message = @subscription.telegram_messages.last
        assert_equal "assistant", telegram_message.role
        assert_equal "Hello <friend>", telegram_message.text
        assert_equal 77, telegram_message.telegram_message_id
        assert_equal({}, telegram_message.media_metadata)
      end

      test "agent-scoped key can reply to a Telegram thread" do
        fake_ok = OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 78 } }.to_json)

        Net::HTTP.stub :post, fake_ok do
          post api_v1_telegram_messages_url,
            params: { reply_to: @subscription.to_param, text: "Thread reply" },
            headers: { "Authorization" => "Bearer #{@token}" }
        end

        assert_response :created
        assert_equal @subscription.to_param, JSON.parse(response.body).dig("delivered", 0, "thread_id")
        assert_equal "Thread reply", @subscription.telegram_messages.last.text
      end

      test "agent-scoped key sends an attached image as a Telegram photo" do
        fake_ok = OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 79 } }.to_json)

        requests = capture_multipart_requests(fake_ok) do
          post api_v1_telegram_messages_url,
            params: {
              recipient: "daniel",
              text: "A <bright> thing",
              media: fixture_file_upload("test_image.png", "image/png")
            },
            headers: { "Authorization" => "Bearer #{@token}" }
        end

        assert_response :created
        assert_equal 1, requests.length
        request = requests.first
        assert_equal "/bot#{@agent.telegram_bot_token}/sendPhoto", request.path
        assert_match %r{\Amultipart/form-data\z}, request.content_type
        assert_equal "111", multipart_field(request, "chat_id")
        assert_equal "A &lt;bright&gt; thing", multipart_field(request, "caption")
        assert_equal "HTML", multipart_field(request, "parse_mode")

        media = multipart_part(request, "photo")
        assert_respond_to media[1], :read
        assert_equal "test_image.png", media[2][:filename]
        assert_equal "image/png", media[2][:content_type]

        telegram_message = @subscription.telegram_messages.last
        assert_equal "photo", telegram_message.media_kind
        assert_equal "ready", telegram_message.media_status
        assert_equal "A <bright> thing", telegram_message.text
        assert telegram_message.media.attached?
      end

      test "agent-scoped key sends an attachment without text" do
        fake_ok = OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 80 } }.to_json)

        requests = capture_multipart_requests(fake_ok) do
          post api_v1_telegram_messages_url,
            params: {
              recipient: "daniel",
              media: fixture_file_upload("test.txt", "text/plain")
            },
            headers: { "Authorization" => "Bearer #{@token}" }
        end

        assert_response :created
        request = requests.first
        assert_equal "/bot#{@agent.telegram_bot_token}/sendDocument", request.path
        assert_nil multipart_field(request, "caption")

        media = multipart_part(request, "document")
        assert_respond_to media[1], :read
        assert_equal "test.txt", media[2][:filename]
        assert_equal "text/plain", media[2][:content_type]

        telegram_message = @subscription.telegram_messages.last
        assert_equal "document", telegram_message.media_kind
        assert_equal "[Document: test.txt]", telegram_message.text
        assert telegram_message.media.attached?
      end

      test "retries a rejected photo once as a document" do
        responses = [
          OpenStruct.new(body: { "ok" => false, "description" => "Bad Request: PHOTO_INVALID_DIMENSIONS" }.to_json),
          OpenStruct.new(body: { "ok" => true, "result" => { "message_id" => 81 } }.to_json)
        ]

        requests = capture_multipart_requests(*responses) do
          post api_v1_telegram_messages_url,
            params: {
              recipient: "daniel",
              media: fixture_file_upload("test_image.png", "image/png")
            },
            headers: { "Authorization" => "Bearer #{@token}" }
        end

        assert_response :created
        assert_equal 2, requests.length
        assert_equal "/bot#{@agent.telegram_bot_token}/sendPhoto", requests.first.path
        assert multipart_part(requests.first, "photo")
        assert_operator requests.first.instance_variable_get(:@captured_upload_size), :>, 0
        assert_equal "/bot#{@agent.telegram_bot_token}/sendDocument", requests.second.path
        assert multipart_part(requests.second, "document")
        assert_equal(
          requests.first.instance_variable_get(:@captured_upload_size),
          requests.second.instance_variable_get(:@captured_upload_size)
        )

        telegram_message = @subscription.telegram_messages.last
        assert_equal "document", telegram_message.media_kind
        assert_equal "[Document: test_image.png]", telegram_message.text
        assert_equal 81, telegram_message.telegram_message_id
      end

      test "rejects an overlong media caption before sending" do
        post api_v1_telegram_messages_url,
          params: {
            recipient: "daniel",
            text: "a" * 1_025,
            media: fixture_file_upload("test_image.png", "image/png")
          },
          headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :unprocessable_entity
        assert_equal "caption is too long (max 1024 characters)", JSON.parse(response.body)["error"]
        assert_empty @subscription.telegram_messages
      end

      test "user-scoped key cannot send telegram messages" do
        user_key = ApiKey.generate_for(@user, name: "User key")

        post api_v1_telegram_messages_url,
          params: { recipient: "daniel", text: "Hello" },
          headers: { "Authorization" => "Bearer #{user_key.raw_token}" }

        assert_response :forbidden
      end

      test "returns not found when recipient does not match active subscriber" do
        post api_v1_telegram_messages_url,
          params: { recipient: "paulina", text: "Hello" },
          headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :not_found
      end

      test "requires configured telegram bot" do
        @agent.update!(telegram_bot_token: nil, telegram_bot_username: nil)

        post api_v1_telegram_messages_url,
          params: { recipient: "daniel", text: "Hello" },
          headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :unprocessable_entity
      end

      private

      def capture_multipart_requests(*responses)
        requests = []
        http = Object.new
        http.define_singleton_method(:request) do |request|
          upload = request.instance_variable_get(:@body_data).find { |part| part.length == 3 }
          request.instance_variable_set(:@captured_upload_size, upload.second.read.bytesize)
          requests << request
          responses.shift
        end

        Net::HTTP.stub :start, ->(*_args, **_options, &block) { block.call(http) } do
          yield
        end
        requests
      end

      def multipart_part(request, name)
        request.instance_variable_get(:@body_data).find { |part| part.first == name }
      end

      def multipart_field(request, name)
        multipart_part(request, name)&.second
      end

    end
  end
end
