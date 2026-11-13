require "test_helper"
require "webmock/minitest"
require "minitest/mock"
require "ostruct"

class Services::PostizMediaUploadTest < ActiveSupport::TestCase
  setup do
    @adapter = Services::PostizAdapter.new(nil)
    @uploader = Services::PostizMediaUpload.new(@adapter)
    @base = "https://api.postiz.com/public/v1"
    @connection = OpenStruct.new(id: 42, credential_payload_hash: { "api_base" => @base, "api_token" => "secret" })
    @files = []
  end

  teardown do
    @files.each { |file| file.tempfile.close! }
  end

  def upload(bytes = "\x89PNG\r\n\x1a\npayload".b, type = "image/png")
    io = Tempfile.new("postiz-test")
    io.binmode
    io.write(bytes)
    io.rewind
    ActionDispatch::Http::UploadedFile.new(tempfile: io, type: type,
      filename: "../../evil\r\nAuthorization: stolen.png").tap { |file| @files << file }
  end

  def call(file = upload)
    @adapter.stub(:resolve_addresses, ["93.184.216.34"]) do
      @uploader.call(@connection, file: file)
    end
  end

  def receipt
    { "id" => "media1", "path" => "https://cdn.example.com/media/file.png" }
  end

  test "multipart file uses generated filename and returns only validated receipt" do
    post = stub_request(:post, "#{@base}/upload").with do |request|
      assert_equal "secret", request.headers["Authorization"]
      assert_match(/multipart\/form-data; boundary=/, request.headers["Content-Type"])
      assert_match(/name="file"; filename="[a-f0-9]{32}\.png"/, request.body)
      refute_includes request.body, "evil"
      refute_includes request.body, "stolen"
      true
    end.to_return(body: receipt.merge("token" => "leaked", "nested" => { "secret" => "leaked" }).to_json)
    result = call
    assert_equal receipt, result.slice("id", "path")
    assert_equal %w[id path upload_token], result.keys.sort
    signed = Rails.application.message_verifier("postiz-media").verify(result.fetch("upload_token"), purpose: "postiz-media")
    assert_equal receipt.merge("connection_id" => 42), signed
    assert_requested post, times: 1
    assert_not_requested :get, /.*/
  end

  test "invalid types magic empty and oversized files never send a request" do
    [upload("hello", "text/plain"), upload("<svg/>", "image/png"), upload("")].each do |file|
      assert_raises(Services::AdapterError) { call(file) }
    end
    file = upload
    file.stub(:size, Services::PostizMediaUpload::MAX_BYTES + 1) do
      assert_raises(Services::AdapterError) { call(file) }
    end
    assert_not_requested :any, /.*/
  end

  test "actual bytes are bounded even when declared size lies" do
    file = upload
    count = 0
    reader = lambda do |_length|
      count += 1
      count == 1 ? "\x89PNG\r\n\x1a\n".b : ("x" * (1024 * 1024))
    end
    file.stub(:read, reader) do
      assert_raises(Services::AdapterError) { call(file) }
    end
    assert_not_requested :any, /.*/
  end

  test "all supported signatures are accepted but mismatched types are rejected" do
    samples = {
      "image/jpeg" => "\xff\xd8\xffrest".b,
      "image/png" => "\x89PNG\r\n\x1a\n".b,
      "image/webp" => "RIFF\x10\x00\x00\x00WEBPVP8 ".b,
      "video/mp4" => [24].pack("N") + "ftypisom" + "\x00" * 12
    }
    samples.each do |type, bytes|
      assert @uploader.send(:magic?, type, bytes)
      refute @uploader.send(:magic?, type, "<html>")
    end
  end

  test "bad receipts are rejected without exposing upstream content" do
    invalid = [
      [], {}, receipt.merge("id" => { "secret" => "leaked" }),
      receipt.merge("id" => "<script>"),
      *%w[http://cdn.example.com/file https://user:secret@cdn.example.com/file
        https://127.0.0.1/file https://cdn.example.com/file?token=secret
        https://cdn.example.com/file#secret https://cdn.example.com/%2e%2e/file
        https://cdn.example.com/../file].map { |path| receipt.merge("path" => path) }
    ]
    invalid.each do |value|
      stub_request(:post, "#{@base}/upload").to_return(body: value.to_json)
      @adapter.stub(:public_address_for, lambda { |host|
        raise Services::PostizAdapter::Error, "private secret" if host == "127.0.0.1"
        "93.184.216.34"
      }) do
        error = assert_raises(Services::AdapterError) { @uploader.call(@connection, file: upload) }
        refute_includes error.message, "secret"
      end
    end
  end

  test "redirects failures malformed and excessive responses never retry" do
    [302, 401, 413, 500].each do |status|
      WebMock.reset_executed_requests!
      post = stub_request(:post, "#{@base}/upload").to_return(status: status, body: "secret",
        headers: { "Location" => "https://evil.example/file" })
      assert_raises(Services::AdapterError) { call }
      assert_requested post, times: 1
    end
    ["not json secret", "x" * (Services::PostizMediaUpload::MAX_RECEIPT_BYTES + 1)].each do |body|
      stub_request(:post, "#{@base}/upload").to_return(body: body)
      error = assert_raises(Services::AdapterError) { call }
      refute_includes error.message, "secret"
    end
    assert_not_requested :any, /evil.example/
  end

  test "timeouts are safe and attempted once" do
    post = stub_request(:post, "#{@base}/upload").to_timeout
    error = assert_raises(Services::AdapterError) { call }
    assert_includes error.message, "outcome may be unknown"
    refute_includes error.message, "secret"
    assert_requested post, times: 1
  end

  test "mixed private DNS blocks upload before any write" do
    @adapter.stub(:resolve_addresses, ["93.184.216.34", "127.0.0.1"]) do
      assert_raises(Services::AdapterError) { @uploader.call(@connection, file: upload) }
    end
    assert_not_requested :any, /.*/
  end
end
