require "test_helper"
require "open3"
require "socket"

class HelixkitPostMessageTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-post-message")

  test "help documents attachments and the canonical runtime manual" do
    stdout, stderr, status = Open3.capture3("python3", SCRIPT.to_s, "--help")

    assert status.success?, stderr
    assert_includes stdout, "--attach PATH"
    assert_includes stdout, "/usr/local/share/helixkit-agent/soulshouse-api.md"
  end

  test "posts multipart content and repeated attachments" do
    request = capture_request do |url|
      stdout, stderr, status = Open3.capture3(
        {
          "HELIXKIT_APP_URL" => url,
          "HELIXKIT_BEARER_TOKEN" => "hx_test"
        },
        "python3",
        SCRIPT.to_s,
        "chat-123",
        "--attach",
        file_fixture("test_image.png").to_s,
        "--attach",
        file_fixture("test.txt").to_s,
        stdin_data: "A generated image\n"
      )

      assert status.success?, stderr
      assert_includes stdout, "\"ok\":true"
    end

    assert_equal "POST /api/v1/conversations/chat-123/messages HTTP/1.1", request[:request_line]
    assert_equal "Bearer hx_test", request[:headers]["authorization"]
    assert_match %r{\Amultipart/form-data; boundary=}, request[:headers]["content-type"]
    assert_includes request[:body], 'name="content"'
    assert_includes request[:body], "A generated image"
    assert_includes request[:body], 'name="files[]"; filename="test_image.png"'
    assert_includes request[:body], "Content-Type: image/png"
    assert_includes request[:body], 'name="files[]"; filename="test.txt"'
    assert_includes request[:body], "Content-Type: text/plain"
  end

  test "posts an image without message content" do
    request = capture_request do |url|
      _stdout, stderr, status = Open3.capture3(
        {
          "HELIXKIT_APP_URL" => url,
          "HELIXKIT_BEARER_TOKEN" => "hx_test"
        },
        "python3",
        SCRIPT.to_s,
        "chat-123",
        "--attach",
        file_fixture("test_image.png").to_s,
        stdin_data: ""
      )

      assert status.success?, stderr
    end

    assert_includes request[:body], 'name="content"'
    assert_includes request[:body], 'name="files[]"; filename="test_image.png"'
  end

  test "keeps JSON for text-only posts" do
    request = capture_request do |url|
      _stdout, stderr, status = Open3.capture3(
        {
          "HELIXKIT_APP_URL" => url,
          "HELIXKIT_BEARER_TOKEN" => "hx_test"
        },
        "python3",
        SCRIPT.to_s,
        "chat-123",
        stdin_data: "Text only"
      )

      assert status.success?, stderr
    end

    assert_equal "application/json", request[:headers]["content-type"]
    assert_equal({ "content" => "Text only" }, JSON.parse(request[:body]))
  end

  private

  def capture_request
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = Queue.new
    thread = Thread.new do
      socket = server.accept
      request_line = socket.gets&.strip
      headers = {}
      while (line = socket.gets)
        line = line.strip
        break if line.empty?
        name, value = line.split(":", 2)
        headers[name.downcase] = value.to_s.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      captured << { request_line: request_line, headers: headers, body: body }
      payload = '{"ok":true}'
      socket.write("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      socket.close
    ensure
      server.close
    end

    yield "http://127.0.0.1:#{port}"
    captured.pop
  ensure
    thread&.join(2)
    server&.close unless server&.closed?
  end

end
