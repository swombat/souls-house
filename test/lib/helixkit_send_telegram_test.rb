require "test_helper"
require "open3"
require "socket"

class HelixkitSendTelegramTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-send-telegram")

  test "help documents attachments and the canonical runtime manual" do
    stdout, stderr, status = Open3.capture3("python3", SCRIPT.to_s, "--help")

    assert status.success?, stderr
    assert_includes stdout, "--attach PATH"
    assert_includes stdout, "/usr/local/share/helixkit-agent/soulshouse-api.md"
  end

  test "posts a multipart Telegram attachment with an optional caption" do
    request = capture_request do |url|
      stdout, stderr, status = Open3.capture3(
        {
          "HELIXKIT_APP_URL" => url,
          "HELIXKIT_BEARER_TOKEN" => "hx_test"
        },
        "python3",
        SCRIPT.to_s,
        "daniel",
        "--attach",
        file_fixture("test_image.png").to_s,
        stdin_data: "A generated image\n"
      )

      assert status.success?, stderr
      assert_includes stdout, "\"ok\":true"
    end

    assert_equal "POST /api/v1/telegram_messages HTTP/1.1", request[:request_line]
    assert_equal "Bearer hx_test", request[:headers]["authorization"]
    assert_match %r{\Amultipart/form-data; boundary=}, request[:headers]["content-type"]
    assert_includes request[:body], 'name="recipient"'
    assert_includes request[:body], "daniel"
    assert_includes request[:body], 'name="text"'
    assert_includes request[:body], "A generated image"
    assert_includes request[:body], 'name="media"; filename="test_image.png"'
    assert_includes request[:body], "Content-Type: image/png"
  end

  test "posts an attachment without message text" do
    request = capture_request do |url|
      _stdout, stderr, status = Open3.capture3(
        {
          "HELIXKIT_APP_URL" => url,
          "HELIXKIT_BEARER_TOKEN" => "hx_test"
        },
        "python3",
        SCRIPT.to_s,
        "--reply-to",
        "thread-123",
        "--attach",
        file_fixture("test_image.png").to_s,
        stdin_data: ""
      )

      assert status.success?, stderr
    end

    assert_includes request[:body], 'name="reply_to"'
    assert_includes request[:body], "thread-123"
    assert_includes request[:body], 'name="media"; filename="test_image.png"'
  end

  test "keeps JSON for text-only messages" do
    request = capture_request do |url|
      _stdout, stderr, status = Open3.capture3(
        {
          "HELIXKIT_APP_URL" => url,
          "HELIXKIT_BEARER_TOKEN" => "hx_test"
        },
        "python3",
        SCRIPT.to_s,
        "daniel",
        stdin_data: "Text only"
      )

      assert status.success?, stderr
    end

    assert_equal "application/json", request[:headers]["content-type"]
    assert_equal({ "text" => "Text only", "recipient" => "daniel" }, JSON.parse(request[:body]))
  end

  test "stdin preserves literal escapes for direct and reply JSON and multipart messages" do
    body = "before\n```sh\nprintf '%s\\n' 'hello'\n```\nC:\\name regex \\n\\d+ literal \\r\\n\n"
    [ false, true ].each do |reply|
      [ false, true ].each do |attachment|
        [ false, true ].each do |argv|
          request = capture_request do |url|
            args = [ "python3", SCRIPT.to_s ]
            args += reply ? [ "--reply-to", "thread-123" ] : [ "daniel" ]
            args << body if argv
            args += [ "--attach", file_fixture("test.txt").to_s ] if attachment
            _stdout, stderr, status = Open3.capture3(
              { "SOULSHOUSE_APP_URL" => url, "SOULSHOUSE_BEARER_TOKEN" => "hx_test" },
              *args, stdin_data: argv ? "ignored stdin" : body
            )
            assert status.success?, stderr
          end
          expected = argv ? body.gsub("\\r\\n", "\n").gsub("\\n", "\n").strip : body.strip
          if attachment
            assert_includes request[:body], "name=\"text\"\r\n\r\n#{expected}\r\n"
          else
            assert_equal expected, JSON.parse(request[:body]).fetch("text")
          end
        end
      end
    end
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
