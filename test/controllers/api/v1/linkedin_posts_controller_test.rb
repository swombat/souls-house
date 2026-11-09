require "test_helper"
require "webmock/minitest"
require "support/linkedin_test_helpers"

module Api
  module V1
    class LinkedinPostsControllerTest < ActionDispatch::IntegrationTest

      include LinkedinTestHelpers
      include ActiveJob::TestHelper

      POSTS_URL = "https://api.linkedin.com/rest/posts".freeze

      setup do
        @user = users(:user_1)
        @agent = agents(:research_assistant)
        @api_key = ApiKey.generate_for(@user, name: "Resident LinkedIn", agent: @agent)
        @connection = linkedin_connection(account: @agent.account, user: @user)
        @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true)
      end

      test "posts text and returns the post URL; LinkedIn gets the house-held token" do
        stub = stub_request(:post, POSTS_URL)
          .with(headers: { "Authorization" => "Bearer li-access" })
          .with { |request| JSON.parse(request.body)["author"] == "urn:li:person:abc123" }
          .to_return(status: 201, headers: { "x-restli-id" => "urn:li:share:7100000000000000001" })

        post_linkedin(text: "Hello (world)", key: "k1")

        assert_response :created
        json = JSON.parse(response.body)
        assert_equal "posted", json["status"]
        assert_equal "https://www.linkedin.com/feed/update/urn:li:share:7100000000000000001/", json["url"]
        assert_requested stub
        assert_equal @agent, LinkedinPost.last.agent
      end

      test "a repeated key answers 200 and does not post again; a different text with it is 422" do
        stub = stub_request(:post, POSTS_URL).to_return(status: 201, headers: { "x-restli-id" => "urn:li:share:7100000000000000002" })

        post_linkedin(text: "Hello", key: "k1")
        post_linkedin(text: "Hello", key: "k1")
        assert_response :ok
        assert JSON.parse(response.body)["replayed"]

        post_linkedin(text: "Something else", key: "k1")
        assert_response :unprocessable_entity
        assert_requested stub, times: 1
      end

      test "requires an Idempotency-Key" do
        post_linkedin(text: "Hello", key: nil)

        assert_response :bad_request
      end

      test "a resident the owner has not switched on cannot post, and nothing is sent" do
        @access.update!(enabled: false)

        post_linkedin(text: "Hello", key: "k1")

        assert_response :forbidden
        assert_equal "not_connected", JSON.parse(response.body)["code"]
        assert_not_requested :post, POSTS_URL
      end

      test "an ended sign-in is refused with a readable reason and the card asks to reconnect" do
        @connection.replace_credential_payload_without_reconciliation!(
          @connection.credential_payload_hash.merge("expires_at" => 1.day.ago.utc.iso8601)
        )

        post_linkedin(text: "Hello", key: "k1")

        assert_response :conflict
        json = JSON.parse(response.body)
        assert_equal "reconnect_needed", json["failure_reason"]
        assert_match(/LinkedIn member sign-ins last 60 days/, json["error"])
        assert_equal "reauthorizing", @connection.reload.status
        assert_not_requested :post, POSTS_URL

        post_linkedin(text: "Hello again", key: "k2")
        assert_response :conflict
        assert_equal "reconnect_needed", JSON.parse(response.body)["code"]
      end

      test "an unknown outcome is 504, never retried, 409 on the same key, and can be resolved" do
        stub = stub_request(:post, POSTS_URL).to_return(status: 502)

        post_linkedin(text: "Hello", key: "k1")
        assert_response :gateway_timeout
        id = JSON.parse(response.body)["id"]

        post_linkedin(text: "Hello", key: "k1")
        assert_response :conflict
        assert_requested stub, times: 1

        patch "/api/v1/linkedin_posts/#{id}",
              params: { resolution: "posted", post_url: "https://www.linkedin.com/feed/update/urn%3Ali%3Ashare%3A7100000000000000003/" },
              headers: headers, as: :json
        assert_response :ok
        json = JSON.parse(response.body)
        assert_equal "resolved_posted", json["status"]
        assert_equal "urn:li:share:7100000000000000003", json["post_urn"]
      end

      test "an image post is queued, uploaded in the background, then posted" do
        stub_request(:post, "https://api.linkedin.com/rest/images?action=initializeUpload")
          .to_return(status: 200, body: { value: { image: "urn:li:image:I9", uploadUrl: "https://www.linkedin.com/dms-uploads/I9" } }.to_json)
        upload = stub_request(:put, "https://www.linkedin.com/dms-uploads/I9").to_return(status: 201)
        create = stub_request(:post, POSTS_URL)
          .with { |request| JSON.parse(request.body).dig("content", "media", "id") == "urn:li:image:I9" }
          .to_return(status: 201, headers: { "x-restli-id" => "urn:li:share:7100000000000000004" })

        post "/api/v1/linkedin_posts",
             params: { text: "With a picture", media: fixture_file_upload("test_image.png", "image/png") },
             headers: headers.merge("Idempotency-Key" => "img-1")
        assert_response :accepted
        id = JSON.parse(response.body)["id"]
        assert_equal "pending", JSON.parse(response.body)["status"]

        perform_enqueued_jobs(only: LinkedinPostJob)

        get "/api/v1/linkedin_posts/#{id}", headers: headers
        json = JSON.parse(response.body)
        assert_equal "posted", json["status"]
        assert_equal "urn:li:image:I9", LinkedinPost.find_by_obfuscated_id(id).media_urn
        assert_requested upload
        assert_requested create
      end

      test "an unsupported file type is refused before anything is stored" do
        post "/api/v1/linkedin_posts",
             params: { text: "x", media: fixture_file_upload("test.txt", "text/plain") },
             headers: headers.merge("Idempotency-Key" => "bad-1")

        assert_response :unprocessable_entity
        assert_equal "media_type", JSON.parse(response.body)["code"]
        assert_equal 0, LinkedinPost.count
      end

      # Mira's P1 on 169cdeae: the upload can take minutes, and whatever
      # changes during it must be seen at the create-post boundary.
      test "access switched off during the upload: nothing is posted" do
        image_upload_that { @access.update!(enabled: false) }

        post_image_and_run_job

        assert_not_requested :post, POSTS_URL
        stored = LinkedinPost.last
        assert_equal "failed", stored.status
        assert_equal "access_removed", stored.failure_reason
      end

      test "connection revoked during the upload: nothing is posted" do
        image_upload_that { @connection.update_columns(status: "revoked") }

        post_image_and_run_job

        assert_not_requested :post, POSTS_URL
        assert_equal "failed", LinkedinPost.last.status
        assert_equal "token_unavailable", LinkedinPost.last.failure_reason
      end

      test "reconnected during the upload: the post goes out with the new token" do
        create = image_upload_that(token: "li-fresh") { reconnect!("li-fresh") }

        post_image_and_run_job

        assert_requested create
        assert_not_requested :post, POSTS_URL, headers: { "Authorization" => "Bearer li-access" }
        assert_equal "posted", LinkedinPost.last.status
      end

      # Mira's second pass on c23a9212: repairing the connection after a
      # failure must only touch the grant that failed.
      test "a 401 on the old token after a mid-upload reconnect leaves the new grant connected" do
        stub_request(:post, "https://api.linkedin.com/rest/images?action=initializeUpload").to_return do |_request|
          reconnect!("li-fresh")
          { status: 401, body: "{}" }
        end

        post_image_and_run_job

        assert_not_requested :post, POSTS_URL
        assert_equal "unauthorized", LinkedinPost.last.failure_reason
        assert_equal "connected", @connection.reload.status
      end

      test "a 401 on the current token marks the connection for reconnecting" do
        stub_request(:post, "https://api.linkedin.com/rest/images?action=initializeUpload").to_return(status: 401, body: "{}")

        post_image_and_run_job

        assert_equal "unauthorized", LinkedinPost.last.failure_reason
        assert_equal "reauthorizing", @connection.reload.status
      end

      test "a grant found ended at create-post stays marked after the send transaction rolls back" do
        @connection.replace_credential_payload_without_reconciliation!(
          @connection.credential_payload_hash.merge("expires_at" => 1.minute.ago.utc.iso8601)
        )

        post_linkedin(text: "Hello", key: "ended-1")

        assert_not_requested :post, POSTS_URL
        assert_equal "reconnect_needed", LinkedinPost.last.failure_reason
        assert_equal "reauthorizing", @connection.reload.status
      end

      test "the ended-grant repair skips a reconnect that committed after the failure" do
        reconnect!("li-fresh")

        LinkedinPoster.new(agent: @agent).send(:mark_reauthorizing, @connection, token: "li-access")
        assert_equal "connected", @connection.reload.status

        LinkedinPoster.new(agent: @agent).send(:mark_reauthorizing, @connection, token: "li-fresh")
        assert_equal "reauthorizing", @connection.reload.status
      end

      test "a resident cannot read another resident's post" do
        stub_request(:post, POSTS_URL).to_return(status: 201, headers: { "x-restli-id" => "urn:li:share:7100000000000000005" })
        post_linkedin(text: "Mine", key: "k1")
        id = JSON.parse(response.body)["id"]

        other = agents(:other_account_agent)
        other_key = ApiKey.generate_for(other.account.owner || @user, name: "Other", agent: other)
        get "/api/v1/linkedin_posts/#{id}", headers: { "Authorization" => "Bearer #{other_key.raw_token}" }

        assert_response :not_found
      end

      private

      def headers
        { "Authorization" => "Bearer #{@api_key.raw_token}" }
      end

      def post_linkedin(text:, key:)
        extra = key ? { "Idempotency-Key" => key } : {}
        post "/api/v1/linkedin_posts", params: { text: }, headers: headers.merge(extra), as: :json
      end

      # Stubs an image upload whose PUT runs the block (the change made while
      # the upload is in flight); returns the create-post stub, which only
      # matches the given bearer token.
      def image_upload_that(token: "li-access", &during_upload)
        stub_request(:post, "https://api.linkedin.com/rest/images?action=initializeUpload")
          .to_return(status: 200, body: { value: { image: "urn:li:image:I7", uploadUrl: "https://www.linkedin.com/dms-uploads/I7" } }.to_json)
        stub_request(:put, "https://www.linkedin.com/dms-uploads/I7").to_return do |_request|
          during_upload.call
          { status: 201 }
        end
        stub_request(:post, POSTS_URL).to_return(status: 201, headers: { "x-restli-id" => "urn:li:share:7100000000000000009" })
        stub_request(:post, POSTS_URL)
          .with(headers: { "Authorization" => "Bearer #{token}" })
          .to_return(status: 201, headers: { "x-restli-id" => "urn:li:share:7100000000000000008" })
      end

      def reconnect!(token)
        @connection.replace_credential_payload_without_reconciliation!(
          @connection.reload.credential_payload_hash.merge("access_token" => token, "expires_at" => 60.days.from_now.utc.iso8601)
        )
      end

      def post_image_and_run_job
        post "/api/v1/linkedin_posts",
             params: { text: "During the upload", media: fixture_file_upload("test_image.png", "image/png") },
             headers: headers.merge("Idempotency-Key" => "upload-#{SecureRandom.hex(4)}")
        assert_response :accepted
        perform_enqueued_jobs(only: LinkedinPostJob)
      end

    end
  end
end
