require "test_helper"
require "webmock/minitest"

class LinkedinPublisherTest < ActiveSupport::TestCase

  POSTS_URL = "https://api.linkedin.com/rest/posts".freeze

  setup do
    @publisher = LinkedinPublisher.new(access_token: "tok", author_urn: "urn:li:person:abc", sleeper: ->(_) { })
  end

  test "escapes every Little Text reserved character" do
    assert_equal "a \\(b\\) \\#tag \\@x \\_y\\_ \\\\ \\* \\~ \\| \\{\\} \\[\\] \\<\\>",
                 LinkedinPublisher.escape("a (b) #tag @x _y_ \\ * ~ | {} [] <>")
  end

  test "creates the post with the version headers and reads the URN from x-restli-id" do
    stub = stub_request(:post, POSTS_URL)
      .with(headers: { "Linkedin-Version" => LinkedinPublisher::VERSION, "X-Restli-Protocol-Version" => "2.0.0", "Authorization" => "Bearer tok" })
      .with { |request| JSON.parse(request.body).values_at("author", "commentary", "visibility") == [ "urn:li:person:abc", "Hi \\(there\\)", "PUBLIC" ] }
      .to_return(status: 201, headers: { "x-restli-id" => "urn:li:share:7000000000000000001" })

    assert_equal "urn:li:share:7000000000000000001", @publisher.create_post(text: "Hi (there)")
    assert_requested stub
  end

  test "a 5xx or a timeout after sending is an unknown outcome; a 4xx is not sent" do
    stub_request(:post, POSTS_URL).to_return(status: 503)
    assert_raises(LinkedinPublisher::OutcomeUnknown) { @publisher.create_post(text: "x") }

    stub_request(:post, POSTS_URL).to_raise(Net::ReadTimeout)
    assert_raises(LinkedinPublisher::OutcomeUnknown) { @publisher.create_post(text: "x") }

    stub_request(:post, POSTS_URL).to_return(status: 422, body: { message: "Content is a duplicate" }.to_json)
    error = assert_raises(LinkedinPublisher::NotSent) { @publisher.create_post(text: "x") }
    assert_equal "rejected", error.reason
    assert_match(/duplicate/, error.message)
  end

  test "a 201 without a post id is an unknown outcome" do
    stub_request(:post, POSTS_URL).to_return(status: 201)

    assert_raises(LinkedinPublisher::OutcomeUnknown) { @publisher.create_post(text: "x") }
  end

  test "uploads a video in its parts, finalizes with the ETags and waits until it is available" do
    bytes = "a" * 10 + "b" * 6
    stub_request(:post, "https://api.linkedin.com/rest/videos?action=initializeUpload")
      .with { |request| JSON.parse(request.body).dig("initializeUploadRequest", "fileSizeBytes") == 16 }
      .to_return(status: 200, body: { value: {
        video: "urn:li:video:V1", uploadToken: "",
        uploadInstructions: [
          { uploadUrl: "https://www.linkedin.com/dms-uploads/V1/part1", firstByte: 0, lastByte: 9 },
          { uploadUrl: "https://www.linkedin.com/dms-uploads/V1/part2", firstByte: 10, lastByte: 15 }
        ]
      } }.to_json)
    part1 = stub_request(:put, "https://www.linkedin.com/dms-uploads/V1/part1").with(body: "a" * 10).to_return(status: 200, headers: { "ETag" => "\"e1\"" })
    part2 = stub_request(:put, "https://www.linkedin.com/dms-uploads/V1/part2").with(body: "b" * 6).to_return(status: 200, headers: { "ETag" => "\"e2\"" })
    finalize = stub_request(:post, "https://api.linkedin.com/rest/videos?action=finalizeUpload")
      .with { |request| JSON.parse(request.body).dig("finalizeUploadRequest", "uploadedPartIds") == %w[e1 e2] }
      .to_return(status: 200, body: "")
    stub_request(:get, "https://api.linkedin.com/rest/videos/urn%3Ali%3Avideo%3AV1")
      .to_return({ status: 200, body: { status: "PROCESSING" }.to_json }, { status: 200, body: { status: "AVAILABLE" }.to_json })

    assert_equal "urn:li:video:V1", @publisher.upload_video(StringIO.new(bytes), size: 16)
    assert_requested part1
    assert_requested part2
    assert_requested finalize
  end

  test "a video LinkedIn cannot process is not sent" do
    stub_request(:post, "https://api.linkedin.com/rest/videos?action=initializeUpload")
      .to_return(status: 200, body: { value: { video: "urn:li:video:V2", uploadToken: "",
                                               uploadInstructions: [ { uploadUrl: "https://www.linkedin.com/up/V2", firstByte: 0, lastByte: 3 } ] } }.to_json)
    stub_request(:put, "https://www.linkedin.com/up/V2").to_return(status: 200, headers: { "ETag" => "e" })
    stub_request(:post, "https://api.linkedin.com/rest/videos?action=finalizeUpload").to_return(status: 200)
    stub_request(:get, %r{/rest/videos/}).to_return(status: 200, body: { status: "PROCESSING_FAILED", processingFailureReason: "Bad codec" }.to_json)

    error = assert_raises(LinkedinPublisher::NotSent) { @publisher.upload_video(StringIO.new("abcd"), size: 4) }
    assert_equal "media_failed", error.reason
    assert_match(/Bad codec/, error.message)
  end

  test "refuses an upload URL outside linkedin.com" do
    stub_request(:post, "https://api.linkedin.com/rest/images?action=initializeUpload")
      .to_return(status: 200, body: { value: { image: "urn:li:image:I1", uploadUrl: "https://evil.example/up" } }.to_json)

    error = assert_raises(LinkedinPublisher::NotSent) { @publisher.upload_image(StringIO.new("png"), content_type: "image/png") }
    assert_match(/outside linkedin.com/, error.message)
  end

end
