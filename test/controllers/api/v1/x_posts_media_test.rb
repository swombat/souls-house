require "test_helper"
require "webmock/minitest"

# X posts with media and long text, faked at X's HTTP boundary. These prove
# what the house does with X's answers; they prove nothing about Daniel's
# actual grant or X's live acceptance.
module Api
  module V1
    class XPostsMediaTest < ActionDispatch::IntegrationTest

      X = "https://api.x.com/2".freeze
      TWEETS_URL = "#{X}/tweets".freeze
      ME_URL = "#{X}/users/me?user.fields=subscription_type".freeze
      INIT_URL = "#{X}/media/upload/initialize".freeze
      MEDIA_ID = "1880028106020515840".freeze
      APPEND_URL = "#{X}/media/upload/#{MEDIA_ID}/append".freeze
      FINALIZE_URL = "#{X}/media/upload/#{MEDIA_ID}/finalize".freeze
      STATUS_URL = "#{X}/media/upload?command=STATUS&media_id=#{MEDIA_ID}".freeze
      SCOPES = "tweet.write tweet.read users.read offline.access media.write".freeze

      # A build-in-public post: about 700 characters, one paragraph break.
      LONG_TEXT = ([ "We shipped a thing today and it was harder than it looked." ] * 7).join(" ") +
        "\n\n" + ([ "The part that held the weight was the boring part." ] * 5).join(" ")

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @api_key = ApiKey.generate_for(@user, name: "Resident X", agent: @agent)
        @integration = XIntegration.create!(
          account: @agent.account, enabled: true, x_username: "househandle", client_id: "own-cid", client_secret: "own-secret",
          access_token: "live-token", refresh_token: "refresh-1", token_expires_at: 2.hours.from_now, granted_scopes: SCOPES
        )
        # Residents post only once switched on for X (x_posting_grants).
        @integration.x_posting_grants.create!(agent: @agent)
        @waits = []
        @on_wait = nil
        waits = @waits
        test_case = self
        @original_sleeper = XMediaUploader.sleeper
        XMediaUploader.sleeper = lambda do |seconds|
          waits << seconds
          test_case.instance_variable_get(:@on_wait)&.call
        end
        # A create that answers, so a test where nothing may be posted fails
        # on assert_not_requested rather than on an unstubbed request. Stubs
        # declared later in a test take precedence.
        stub_request(:post, TWEETS_URL).to_return(status: 201, body: { data: { id: "9999" } }.to_json)
        @video = Tempfile.new([ "clip", ".mp4" ], binmode: true)
        @video.write(Random.bytes(9.megabytes))
        @video.flush
      end

      teardown do
        XMediaUploader.sleeper = @original_sleeper
        @video.close!
      end

      test "a long text and a processed MP4 go out as one post, in one create call" do
        assert XTextLength.weighted_length(LONG_TEXT) > 280
        me = stub_premium("Premium")
        init = stub_request(:post, INIT_URL)
          .with(body: { media_type: "video/mp4", total_bytes: 9.megabytes, media_category: "tweet_video" }.to_json,
                headers: { "Authorization" => "Bearer live-token" })
          .to_return(status: 200, body: { data: { id: MEDIA_ID, media_key: "13_#{MEDIA_ID}", expires_after_secs: 86_400 } }.to_json)
        segments = []
        append = stub_request(:post, APPEND_URL)
          .with { |request| request.headers["Content-Type"].start_with?("multipart/form-data") }
          .to_return do |request|
            segments << request.body[/name="segment_index"\r\n\r\n(\d+)/, 1].to_i
            { status: 204, body: "" }
          end
        stub_request(:post, FINALIZE_URL)
          .to_return(status: 200, body: { data: { id: MEDIA_ID, processing_info: { state: "pending", check_after_secs: 3 } } }.to_json)
        stub_request(:get, STATUS_URL).to_return(
          { status: 200, body: { data: { id: MEDIA_ID, processing_info: { state: "in_progress", check_after_secs: 5 } } }.to_json },
          { status: 200, body: { data: { id: MEDIA_ID, processing_info: { state: "succeeded" } } }.to_json }
        )
        create = stub_request(:post, TWEETS_URL).to_return(status: 201, body: { data: { id: "9001" } }.to_json)

        id = post_video(LONG_TEXT, key: "clip-1")
        assert_equal "pending", TweetLog.find_by_obfuscated_id(id).status
        assert_not_requested create

        perform_enqueued_jobs(only: XPostJob)

        get "/api/v1/x_posts/#{id}", headers: headers
        json = JSON.parse(response.body)
        assert_equal "posted", json["status"]
        assert_equal "https://x.com/househandle/status/9001", json["url"]
        assert_equal "video", json["media_kind"]
        assert_requested me, times: 1
        assert_requested init, times: 1
        assert_requested append, times: 3
        assert_equal [ 0, 1, 2 ], segments
        assert_equal [ 3, 5 ], @waits
        assert_requested :post, TWEETS_URL, times: 1
        assert_requested(:post, TWEETS_URL) do |request|
          body = JSON.parse(request.body)
          body["text"] == LONG_TEXT && body["media"] == { "media_ids" => [ MEDIA_ID ] }
        end
        assert_not TweetLog.find_by_obfuscated_id(id).media.attached?
      end

      test "an image is uploaded in one request as tweet_image and attached" do
        upload = stub_request(:post, "#{X}/media/upload").with do |request|
          request.body.include?("name=\"media_category\"\r\n\r\ntweet_image") && request.body.include?("Content-Type: image/png")
        end.to_return(status: 200, body: { data: { id: "555", media_key: "3_555" } }.to_json)
        create = stub_request(:post, TWEETS_URL)
          .with(body: { text: "A chart", media: { media_ids: [ "555" ] } }.to_json)
          .to_return(status: 201, body: { data: { id: "9002" } }.to_json)

        post "/api/v1/x_posts", params: { text: "A chart", media: fixture_file_upload("test_image.png", "image/png") },
                                headers: headers.merge("Idempotency-Key" => "img-1")
        assert_response :accepted
        perform_enqueued_jobs(only: XPostJob)

        assert_requested upload, times: 1
        assert_requested create, times: 1
        assert_equal "posted", TweetLog.last.status
      end

      test "without media.write a media post is refused up front, and text posting is untouched" do
        @integration.update!(granted_scopes: "tweet.write tweet.read users.read offline.access")
        stub_request(:post, TWEETS_URL).to_return(status: 201, body: { data: { id: "9003" } }.to_json)

        post_video("With a clip", key: "clip-1", expect: :conflict)
        json = JSON.parse(response.body)
        assert_equal "reconnect_for_media", json["code"]
        assert_includes json["error"], "Reconnect X to post media"
        assert_equal 0, TweetLog.count
        assert_enqueued_jobs 0, only: XPostJob

        post "/api/v1/x_posts", params: { text: "Just text" }, headers: headers.merge("Idempotency-Key" => "t-1"), as: :json
        assert_response :created
        assert_requested :post, TWEETS_URL, times: 1
        assert_not_requested :post, INIT_URL
        assert @integration.reload.enabled?
      end

      test "a grant with no recorded scopes counts as no media.write" do
        @integration.update!(granted_scopes: nil)

        post_video("With a clip", key: "clip-1", expect: :conflict)
        assert_equal "reconnect_for_media", JSON.parse(response.body)["code"]
      end

      {
        "X reports no subscription" => [ { status: 200, body: { data: { subscription_type: "None" } }.to_json }, "long_text_not_allowed" ],
        "X reports Basic" => [ { status: 200, body: { data: { subscription_type: "Basic" } }.to_json }, "long_text_not_allowed" ],
        "X leaves the tier out" => [ { status: 200, body: { data: { id: "1" } }.to_json }, "long_text_unconfirmed" ],
        "X cannot be asked" => [ { status: 503, body: "" }, "long_text_unconfirmed" ]
      }.each do |label, (answer, reason)|
        test "long text when #{label}: nothing is uploaded and create is never called" do
          stub_request(:get, ME_URL).to_return(answer)

          id = post_video(LONG_TEXT, key: "clip-1")
          perform_enqueued_jobs(only: XPostJob)

          log = TweetLog.find_by_obfuscated_id(id)
          assert_equal "failed", log.status
          assert_equal reason, log.failure_reason
          assert_match(/over|allows more than 280/, log.error_message)
          assert_not_requested :post, INIT_URL
          assert_not_requested :post, TWEETS_URL
          assert_not log.media.attached?
        end
      end

      test "media X fails to process is never posted" do
        stub_upload(processing: { state: "pending", check_after_secs: 1 })
        stub_request(:get, STATUS_URL)
          .to_return(status: 200, body: { data: { id: MEDIA_ID, processing_info: { state: "failed", error: { message: "InvalidMedia" } } } }.to_json)

        id = post_video("With a clip", key: "clip-1")
        perform_enqueued_jobs(only: XPostJob)

        log = TweetLog.find_by_obfuscated_id(id)
        assert_equal "failed", log.status
        assert_equal "media_failed", log.failure_reason
        assert_includes log.error_message, "InvalidMedia"
        assert_not_requested :post, TWEETS_URL
      end

      test "once X says it is processing, a status answer without a state is never taken as ready" do
        stub_upload(processing: { state: "pending", check_after_secs: 1 })
        stub_request(:get, STATUS_URL).to_return(status: 200, body: { data: { id: MEDIA_ID } }.to_json)

        id = post_video("With a clip", key: "clip-1")
        perform_enqueued_jobs(only: XPostJob)

        log = TweetLog.find_by_obfuscated_id(id)
        assert_equal "media_failed", log.failure_reason
        assert_not_requested :post, TWEETS_URL
      end

      test "a FINALIZE answer that is not a finalize result is never taken as ready" do
        stub_upload(processing: nil)
        stub_request(:post, FINALIZE_URL)
          .to_return(status: 200, body: { errors: [ { title: "Invalid Request", detail: "Segments do not add up" } ] }.to_json)

        id = post_video("With a clip", key: "clip-1")
        perform_enqueued_jobs(only: XPostJob)

        log = TweetLog.find_by_obfuscated_id(id)
        assert_equal "media_failed", log.failure_reason
        assert_not_requested :post, TWEETS_URL
      end

      [ "pending", nil, [ "pending" ] ].each do |malformed|
        test "a FINALIZE whose processing_info is present but #{malformed.inspect} is never taken as ready" do
          stub_upload(processing: nil)
          stub_request(:post, FINALIZE_URL)
            .to_return(status: 200, body: { data: { id: MEDIA_ID, processing_info: malformed } }.to_json)

          id = post_video("With a clip", key: "clip-1")
          perform_enqueued_jobs(only: XPostJob)

          assert_equal "media_failed", TweetLog.find_by_obfuscated_id(id).failure_reason
          assert_not_requested :post, TWEETS_URL
        end
      end

      test "a valid FINALIZE with no processing needed still posts" do
        stub_upload(processing: nil)

        id = post_video("With a clip", key: "clip-1")
        perform_enqueued_jobs(only: XPostJob)

        assert_equal "posted", TweetLog.find_by_obfuscated_id(id).status
        assert_not_requested :get, STATUS_URL
        assert_requested(:post, TWEETS_URL, times: 1) { |request| JSON.parse(request.body)["media"] == { "media_ids" => [ MEDIA_ID ] } }
      end

      test "media still processing at the deadline is never posted" do
        stub_upload(processing: { state: "pending", check_after_secs: 1 })
        stub_request(:get, STATUS_URL)
          .to_return(status: 200, body: { data: { id: MEDIA_ID, processing_info: { state: "in_progress", check_after_secs: 30 } } }.to_json)
        @on_wait = -> { travel XMediaUploader::PROCESSING_LIMIT / 2 }

        id = post_video("With a clip", key: "clip-1")
        perform_enqueued_jobs(only: XPostJob)

        log = TweetLog.find_by_obfuscated_id(id)
        assert_equal "media_failed", log.failure_reason
        assert_not_requested :post, TWEETS_URL
      ensure
        travel_back
      end

      {
        "switching posting off" => [ ->(integration) { integration.update!(enabled: false) }, "posting_disabled" ],
        "switching this resident off for X" => [ ->(integration) { integration.x_posting_grants.delete_all }, "not_granted" ],
        "disconnecting" => [ ->(integration) { integration.disconnect! }, "disconnected" ],
        "reconnecting (possibly as another X account)" => [ ->(integration) { integration.update!(app_generation: integration.app_generation + 1) }, "reconnected" ]
      }.each do |change, (act, reason)|
        test "#{change} while X processes the video means zero create calls" do
          stub_upload(processing: { state: "pending", check_after_secs: 2 })
          stub_request(:get, STATUS_URL)
            .to_return(status: 200, body: { data: { id: MEDIA_ID, processing_info: { state: "succeeded" } } }.to_json)
          integration_id = @integration.id
          @on_wait = -> { act.call(XIntegration.find(integration_id)) }

          id = post_video("With a clip", key: "clip-1")
          perform_enqueued_jobs(only: XPostJob)

          log = TweetLog.find_by_obfuscated_id(id)
          assert_equal "failed", log.status
          assert_equal reason, log.failure_reason
          assert_not_requested :post, TWEETS_URL
        end
      end

      test "a post from before a reconnect never refreshes the new connection's token" do
        stub_upload(processing: nil)
        refresh = stub_request(:post, "#{X}/oauth2/token").to_return(status: 200, body: { access_token: "n", refresh_token: "r", expires_in: 7200 }.to_json)
        id = post_video("With a clip", key: "clip-1")
        @integration.update!(app_generation: @integration.app_generation + 1, token_expires_at: 1.minute.from_now)

        perform_enqueued_jobs(only: XPostJob)

        log = TweetLog.find_by_obfuscated_id(id)
        assert_equal "failed", log.status
        assert_not_requested refresh
        assert_not_requested :post, INIT_URL
        assert_not_requested :post, TWEETS_URL
      end

      test "an ambiguous create stays unknown, and the same submission again makes no second create" do
        stub_upload(processing: nil)
        create = stub_request(:post, TWEETS_URL).to_raise(Net::ReadTimeout)

        id = post_video("With a clip", key: "clip-1")
        perform_enqueued_jobs(only: XPostJob)
        assert_equal "outcome_unknown", TweetLog.find_by_obfuscated_id(id).status

        post_video("With a clip", key: "clip-1", expect: :conflict)
        assert JSON.parse(response.body)["replayed"]
        assert_enqueued_jobs 0, only: XPostJob
        perform_enqueued_jobs(only: XPostJob)

        assert_requested create, times: 1
        assert_equal 1, TweetLog.count
      end

      test "the same key with a different file is a conflict, not the earlier post" do
        stub_upload(processing: nil)
        stub_request(:post, TWEETS_URL).to_return(status: 201, body: { data: { id: "9004" } }.to_json)
        post_video("With a clip", key: "clip-1")

        @video.rewind
        @video.write("different")
        @video.flush
        post_video("With a clip", key: "clip-1", expect: :unprocessable_entity)

        assert_equal "idempotency_key_reused", JSON.parse(response.body)["code"]
        assert_equal 1, TweetLog.count
      end

      test "an unsupported file type is refused before anything is stored" do
        post "/api/v1/x_posts", params: { text: "x", media: fixture_file_upload("test.txt", "text/plain") },
                                headers: headers.merge("Idempotency-Key" => "bad-1")

        assert_response :unprocessable_entity
        assert_equal "media_type", JSON.parse(response.body)["code"]
        assert_equal 0, TweetLog.count
      end

      private

      def headers
        { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

      def post_video(text, key:, expect: :accepted)
        file = Rack::Test::UploadedFile.new(@video.path, "video/mp4", true, original_filename: "clip.mp4")
        post "/api/v1/x_posts", params: { text:, media: file }, headers: headers.merge("Idempotency-Key" => key)
        assert_response expect
        JSON.parse(response.body)["id"]
      end

      def stub_premium(tier)
        stub_request(:get, ME_URL).to_return(status: 200, body: { data: { id: "1", username: "househandle", subscription_type: tier } }.to_json)
      end

      def stub_upload(processing:)
        stub_request(:post, INIT_URL).to_return(status: 200, body: { data: { id: MEDIA_ID } }.to_json)
        stub_request(:post, APPEND_URL).to_return(status: 204, body: "")
        finalize = { data: { id: MEDIA_ID } }
        finalize[:data][:processing_info] = processing if processing
        stub_request(:post, FINALIZE_URL).to_return(status: 200, body: finalize.to_json)
      end

    end
  end
end
