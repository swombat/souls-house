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

  test "ccu-info hits pinned Google Colab origin, strips XSSI prefix, and prints JSON" do
    runner = <<~PYTHON
      import importlib.machinery, importlib.util, io, json, sys
      loader = importlib.machinery.SourceFileLoader("soulshouse_colab", sys.argv[1])
      spec = importlib.util.spec_from_loader(loader.name, loader)
      mod = importlib.util.module_from_spec(spec)
      loader.exec_module(mod)

      seen = []
      class FakeResp(io.BytesIO):
          status = 200
          def __enter__(self): return self
          def __exit__(self, *a): pass
      class FakeOpener:
          def open(self, req, timeout=30):
              seen.append((req.full_url, req.get_header("Authorization")))
              return FakeResp(b")]}'\\n{\\"currentBalance\\": 42.5}")
      mod.NO_REDIRECT_OPENER = FakeOpener()
      rc = mod.run_ccu_info("short-lived-colab-token")
      assert rc == 0, rc
      assert seen == [("https://colab.research.google.com/tun/m/ccu-info", "Bearer short-lived-colab-token")], seen
    PYTHON

    stdout, stderr, status = Open3.capture3("python3", "-c", runner, SCRIPT.to_s)
    assert status.success?, stderr
    assert_equal({ "currentBalance" => 42.5 }, JSON.parse(stdout))
    assert_not_includes stdout, "short-lived-colab-token"
  end

  test "check hits pinned Google endpoints and reports scopes and statuses without leaking tokens or bodies" do
    runner = <<~PYTHON
      import importlib.machinery, importlib.util, io, json, sys, urllib.error
      loader = importlib.machinery.SourceFileLoader("soulshouse_colab", sys.argv[1])
      spec = importlib.util.spec_from_loader(loader.name, loader)
      mod = importlib.util.module_from_spec(spec)
      loader.exec_module(mod)

      responses = {
          "https://oauth2.googleapis.com/tokeninfo": (200, b'{"scope":"openid https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/colaboratory","email":"secret@example.com"}'),
          "https://colab.research.google.com/tun/m/ccu-info": (200, b")]}'\\n{\\"secretBalance\\": 99}"),
          "https://colaboratory.googleapis.com/v1beta/runtimes": (200, b'{"runtimes":[]}'),
          "https://colab.pa.googleapis.com/v1/user-info": (404, b'{"error":"not_found"}'),
      }
      seen = []
      class FakeResp(io.BytesIO):
          def __init__(self, status, body):
              super().__init__(body)
              self.status = status
          def __enter__(self): return self
          def __exit__(self, *a): pass
      class FakeOpener:
          def open(self, req, timeout=30):
              seen.append(req.full_url)
              code, body = responses[req.full_url]
              if code >= 400:
                  raise urllib.error.HTTPError(req.full_url, code, "Err", {}, io.BytesIO(body))
              return FakeResp(code, body)
      mod.NO_REDIRECT_OPENER = FakeOpener()
      rc = mod.run_check("svc_123", "short-lived-colab-token")
      assert rc == 0, rc
      assert set(seen) == set(responses.keys()), seen
    PYTHON

    stdout, stderr, status = Open3.capture3("python3", "-c", runner, SCRIPT.to_s)
    assert status.success?, stderr
    report = JSON.parse(stdout)
    assert_equal "svc_123", report["connection_id"]
    assert_equal 200, report["tokeninfo_status"]
    assert_equal true, report["has_colaboratory_scope"]
    assert_equal 200, report.dig("endpoints", "colab_session_ccu_info")
    assert_equal 200, report.dig("endpoints", "colab_public_runtimes")
    assert_equal 404, report.dig("endpoints", "colab_pa_user_info_unverified")
    assert_includes report["scopes"], "https://www.googleapis.com/auth/colaboratory"
    assert_not_includes stdout, "short-lived-colab-token"
    assert_not_includes stdout, "secret@example.com"
    assert_not_includes stdout, "secretBalance"
  end

  test "broker HTTP errors print status only and do not leak response bodies" do
    with_stub_http({
      "/api/v1/service_connections/svc_123/access_token" => [ 409, '{"error":"provider_reauth_required","secret":"do-not-print"}' ]
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
          "SOULSHOUSE_SERVICES_FILE" => manifest.path
        },
        "python3",
        SCRIPT.to_s,
        "check"
      )

      assert_not status.success?
      assert_includes stderr, "HTTP 409"
      assert_not_includes stdout + stderr, "do-not-print"
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
