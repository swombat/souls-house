require "test_helper"
require "json"
require "open3"
require "socket"
require "tempfile"

class SoulshouseColabTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-colab")

  test "exec passes a brokered access token to the child without printing it" do
    request = capture_request do |endpoint|
      manifest = write_manifest([
        {
          "connection_id" => "svc_123",
          "provider" => "google_workspace",
          "credentials" => { "access_token_endpoint" => endpoint }
        }
      ])

      child = Tempfile.new("colab-child")
      child.write(<<~PYTHON)
        #!/usr/bin/env python3
        import os
        import sys
        print("token-present=" + str(os.environ.get("GOOGLE_COLAB_ACCESS_TOKEN") == "short-lived-colab-token"))
        print("args=" + " ".join(sys.argv[1:]))
      PYTHON
      child.close
      File.chmod(0o755, child.path)

      stdout, stderr, status = Open3.capture3(
        {
          "SOULSHOUSE_BEARER_TOKEN" => "hx_test",
          "SOULSHOUSE_SERVICES_FILE" => manifest.path
        },
        "python3",
        SCRIPT.to_s,
        "exec",
        "--",
        child.path,
        "run",
        "--gpu"
      )

      assert status.success?, stderr
      assert_includes stdout, "token-present=True"
      assert_includes stdout, "args=run --gpu"
      assert_not_includes stdout, "short-lived-colab-token"
    ensure
      manifest&.unlink
      child&.unlink
    end

    assert_equal "Bearer hx_test", request[:headers]["authorization"]
  end

  test "ccu-info strips Google XSSI prefix and prints JSON" do
    with_stub_http({
      "/api/v1/service_connections/svc_123/access_token" => [ 200, '{"access_token":"short-lived-colab-token"}' ],
      "/tun/m/ccu-info" => [ 200, ")]}'\n{\"currentBalance\": 42.5}" ]
    }) do |base, requests|
      manifest = write_manifest([
        {
          "connection_id" => "svc_123",
          "provider" => "google_workspace",
          "credentials" => { "access_token_endpoint" => "#{base}/api/v1/service_connections/svc_123/access_token" }
        }
      ])

      stdout, stderr, status = Open3.capture3(
        {
          "SOULSHOUSE_BEARER_TOKEN" => "hx_test",
          "SOULSHOUSE_SERVICES_FILE" => manifest.path,
          "SOULSHOUSE_COLAB_ORIGIN" => base
        },
        "python3",
        SCRIPT.to_s,
        "ccu-info"
      )

      assert status.success?, stderr
      assert_equal({ "currentBalance" => 42.5 }, JSON.parse(stdout))
      assert_not_includes stdout, "short-lived-colab-token"
      colab_req = requests.find { |r| r[:path] == "/tun/m/ccu-info" }
      assert_equal "Bearer short-lived-colab-token", colab_req[:headers]["authorization"]
    ensure
      manifest&.unlink
    end
  end

  test "check reports tokeninfo scopes and both Colab host statuses without leaking tokens or bodies" do
    with_stub_http({
      "/api/v1/service_connections/svc_123/access_token" => [ 200, '{"access_token":"short-lived-colab-token"}' ],
      "/tokeninfo" => [ 200, '{"scope":"openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/colaboratory","email":"secret@example.com"}' ],
      "/tun/m/ccu-info" => [ 200, ")]}'\n{\"secretBalance\": 99}" ],
      "/v1/user-info" => [ 200, '{"subscriptionTier":"PRO_PLUS"}' ]
    }) do |base, _requests|
      manifest = write_manifest([
        {
          "connection_id" => "svc_123",
          "provider" => "google_workspace",
          "credentials" => { "access_token_endpoint" => "#{base}/api/v1/service_connections/svc_123/access_token" }
        }
      ])

      stdout, stderr, status = Open3.capture3(
        {
          "SOULSHOUSE_BEARER_TOKEN" => "hx_test",
          "SOULSHOUSE_SERVICES_FILE" => manifest.path,
          "SOULSHOUSE_GOOGLE_TOKENINFO_URL" => "#{base}/tokeninfo",
          "SOULSHOUSE_COLAB_ORIGIN" => base,
          "SOULSHOUSE_COLAB_PA_ORIGIN" => base
        },
        "python3",
        SCRIPT.to_s,
        "check"
      )

      assert status.success?, stderr
      report = JSON.parse(stdout)
      assert_equal "svc_123", report["connection_id"]
      assert_equal 200, report["tokeninfo_status"]
      assert_equal true, report["has_colaboratory_scope"]
      assert_equal 200, report["colab_session_status"]
      assert_equal 200, report["colab_runtime_status"]
      assert_includes report["scopes"], "https://www.googleapis.com/auth/colaboratory"
      assert_not_includes stdout, "short-lived-colab-token"
      assert_not_includes stdout, "secret@example.com"
      assert_not_includes stdout, "secretBalance"
      assert_not_includes stdout, "PRO_PLUS"
    ensure
      manifest&.unlink
    end
  end

  test "prefers the unique Colab-enabled connection or requires --connection when ambiguous" do
    manifest = write_manifest([
      { "connection_id" => "svc_1", "provider" => "google_workspace", "access" => { "authority" => { "colab" => "none" } } },
      { "connection_id" => "svc_2", "provider" => "google_workspace", "access" => { "authority" => { "colab" => "none" } } }
    ])

    _stdout, stderr, status = Open3.capture3(
      {
        "SOULSHOUSE_BEARER_TOKEN" => "hx_test",
        "SOULSHOUSE_SERVICES_FILE" => manifest.path
      },
      "python3",
      SCRIPT.to_s,
      "check"
    )

    assert_not status.success?
    assert_includes stderr, "--connection"
  ensure
    manifest&.unlink
  end

  private

  def write_manifest(services)
    file = Tempfile.new([ "services", ".yml" ])
    file.write({ "version" => 1, "services" => services }.to_yaml)
    file.close
    file
  end

  def capture_request
    with_stub_http({
      "/api/v1/service_connections/svc_123/access_token" => [ 200, '{"access_token":"short-lived-colab-token","expires_at":"2026-11-24T22:00:00Z"}' ]
    }) do |base, requests|
      yield "#{base}/api/v1/service_connections/svc_123/access_token"
      requests.first
    end
  end

  def with_stub_http(routes)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    requests = []
    running = true
    thread = Thread.new do
      while running
        ready = IO.select([ server ], nil, nil, 0.05)
        next unless ready
        socket = server.accept
        request_line = socket.gets&.strip
        next unless request_line
        method, path = request_line.split(" ", 3)
        headers = {}
        while (line = socket.gets)
          line = line.strip
          break if line.empty?
          name, value = line.split(":", 2)
          headers[name.downcase] = value.to_s.strip
        end
        length = headers["content-length"].to_i
        body = length > 0 ? socket.read(length) : ""
        requests << { method: method, path: path, headers: headers, body: body }
        code, payload = routes.fetch(path, [ 404, '{"error":"not_found"}' ])
        socket.write("HTTP/1.1 #{code} OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
        socket.close
      end
    rescue IOError
      nil
    end

    yield "http://127.0.0.1:#{port}", requests
  ensure
    running = false
    server&.close unless server&.closed?
    thread&.join(2)
  end

end
