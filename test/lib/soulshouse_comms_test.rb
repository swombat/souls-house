require "test_helper"
require "open3"
require "socket"
require "tempfile"

class SoulshouseCommsTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-comms")

  test "messages calls the manifest's endpoint with the resident key and prints JSON" do
    request = nil
    stdout = stderr = status = nil
    request = capture_request('{"chat":{"id":"chat_1"},"messages":[{"provider_message_id":"m1","body":"hi"}]}') do |base|
      with_manifest(base) do |manifest|
        stdout, stderr, status = Open3.capture3(
          { "SOULSHOUSE_BEARER_TOKEN" => "hx_test", "SOULSHOUSE_SERVICES_FILE" => manifest },
          "python3", SCRIPT.to_s, "messages", "--chat", "447700900123@s.whatsapp.net", "--since", "2026-10-09T10:00:00Z", "--limit", "5"
        )
      end
    end

    assert status.success?, stderr
    assert_equal "m1", JSON.parse(stdout).dig("messages", 0, "provider_message_id")
    assert_equal "Bearer hx_test", request[:headers]["authorization"]
    path, query = request[:request_line].split[1].split("?", 2)
    assert_equal "/api/v1/service_connections/svc_123/comms/messages", path
    assert_equal({ "chat" => [ "447700900123@s.whatsapp.net" ], "since" => [ "2026-10-09T10:00:00Z" ], "limit" => [ "5" ] }, CGI.parse(query))
  end

  test "chats needs a choice when several comms connections are present" do
    manifest = Tempfile.new([ "services", ".yml" ])
    manifest.write({ "services" => [
      { "connection_id" => "svc_1", "provider" => "whatsapp" },
      { "connection_id" => "svc_2", "provider" => "whatsapp" }
    ] }.to_yaml)
    manifest.close

    _stdout, stderr, status = Open3.capture3(
      { "HELIXKIT_BEARER_TOKEN" => "hx_test", "HELIXKIT_SERVICES_FILE" => manifest.path },
      "python3", SCRIPT.to_s, "chats"
    )

    assert_not status.success?
    assert_includes stderr, "--connection"
  ensure
    manifest&.unlink
  end

  test "there is no send command" do
    _stdout, stderr, status = Open3.capture3(
      { "SOULSHOUSE_BEARER_TOKEN" => "hx_test" }, "python3", SCRIPT.to_s, "send", "--chat", "x", "hello"
    )
    assert_not status.success?
    assert_includes stderr, "invalid choice"
  end

  private

  def with_manifest(base)
    manifest = Tempfile.new([ "services", ".yml" ])
    manifest.write({ "services" => [ {
      "connection_id" => "svc_123", "provider" => "whatsapp",
      "credentials" => {
        "chats_endpoint" => "#{base}/api/v1/service_connections/svc_123/comms/chats",
        "messages_endpoint" => "#{base}/api/v1/service_connections/svc_123/comms/messages"
      }
    } ] }.to_yaml)
    manifest.close
    yield manifest.path
  ensure
    manifest&.unlink
  end

  def capture_request(payload)
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
      captured << { request_line: request_line, headers: headers }
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
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
