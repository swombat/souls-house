require "test_helper"
require "open3"
require "socket"
require "tempfile"

class HelixkitGwsTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/helixkit-gws")

  test "passes a brokered access token to gws without printing it" do
    request = capture_request do |endpoint|
      manifest = Tempfile.new([ "services", ".yml" ])
      manifest.write({
        "version" => 1,
        "services" => [
          {
            "connection_id" => "svc_123",
            "provider" => "google_workspace",
            "credentials" => { "access_token_endpoint" => endpoint }
          }
        ]
      }.to_yaml)
      manifest.close

      fake_gws = Tempfile.new("gws")
      fake_gws.write(<<~PYTHON)
        #!/usr/bin/env python3
        import os
        import sys
        print("token-present=" + str(bool(os.environ.get("GOOGLE_WORKSPACE_CLI_TOKEN"))))
        print("args=" + " ".join(sys.argv[1:]))
      PYTHON
      fake_gws.close
      File.chmod(0o755, fake_gws.path)

      stdout, stderr, status = Open3.capture3(
        {
          "HELIXKIT_BEARER_TOKEN" => "hx_test",
          "HELIXKIT_SERVICES_FILE" => manifest.path,
          "HELIXKIT_GWS_BINARY" => fake_gws.path
        },
        "python3",
        SCRIPT.to_s,
        "drive",
        "files",
        "list"
      )

      assert status.success?, stderr
      assert_includes stdout, "token-present=True"
      assert_includes stdout, "args=drive files list"
      assert_not_includes stdout, "short-lived-google-token"
    ensure
      manifest&.unlink
      fake_gws&.unlink
    end

    assert_equal "Bearer hx_test", request[:headers]["authorization"]
  end

  test "requires an explicit choice when several Drive identities are present" do
    manifest = Tempfile.new([ "services", ".yml" ])
    manifest.write({
      "services" => [
        { "connection_id" => "svc_1", "provider" => "google_workspace" },
        { "connection_id" => "svc_2", "provider" => "google_workspace" }
      ]
    }.to_yaml)
    manifest.close

    _stdout, stderr, status = Open3.capture3(
      {
        "HELIXKIT_BEARER_TOKEN" => "hx_test",
        "HELIXKIT_SERVICES_FILE" => manifest.path
      },
      "python3",
      SCRIPT.to_s,
      "drive",
      "files",
      "list"
    )

    assert_not status.success?
    assert_includes stderr, "--connection"
  ensure
    manifest&.unlink
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
      captured << { request_line: request_line, headers: headers }
      payload = '{"access_token":"short-lived-google-token","expires_at":"2026-08-28T18:30:00Z"}'
      socket.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      socket.close
    ensure
      server.close
    end

    yield "http://127.0.0.1:#{port}/api/v1/service_connections/svc_123/access_token"
    captured.pop
  ensure
    thread&.join(2)
    server&.close unless server&.closed?
  end

end
