require "test_helper"
require "open3"
require "tmpdir"

# Drives agent-runtime/soulshouse-integrations against a fake souls.house that
# logs what it was sent.
class SoulshouseIntegrationsTest < ActiveSupport::TestCase

  SCRIPT = Rails.root.join("agent-runtime/soulshouse-integrations")
  SECRET = "6489f0c2a1b2c3d4e5f60718:#{'ab' * 32}".freeze

  FAKE_HOUSE = <<~PYTHON
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer
    LOG = sys.argv[1]
    CONNECTION = {"id": "svc_1", "label": "Ghost (Lume writes)", "status": "connected",
                  "connected_by_name": "Lume for Daniel", "residents": [{"id": "a1", "name": "Lume"}]}
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def handle_any(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = self.rfile.read(n).decode() if n else ""
            open(LOG, "a").write(json.dumps({"method": self.command, "path": self.path, "body": body,
                                             "auth": self.headers.get("Authorization")}) + "\\n")
            if self.command == "DELETE":
                out = {"disconnected": {"id": "svc_1"}, "provider_side": "The key is still valid at Ghost until it is rotated or deleted there."}
            else:
                out = {"service_connection": CONNECTION}
            raw = json.dumps(out).encode()
            self.send_response(201 if self.command == "POST" else 200)
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        do_GET = do_POST = do_PATCH = do_DELETE = handle_any
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
  PYTHON

  setup do
    @dir = Dir.mktmpdir("soulshouse-integrations")
    @log = File.join(@dir, "requests.log")
    File.write(File.join(@dir, "fake.py"), FAKE_HOUSE)
    _in, out, @server = Open3.popen2("python3", File.join(@dir, "fake.py"), @log)
    @port = out.gets.to_i
  end

  teardown do
    Process.kill("TERM", @server.pid) rescue nil
    @server.join
    FileUtils.remove_entry(@dir)
  end

  def run_helper(*args, stdin: "")
    env = { "SOULSHOUSE_APP_URL" => "http://127.0.0.1:#{@port}", "SOULSHOUSE_BEARER_TOKEN" => "resident-token" }
    Open3.capture3(env, "python3", SCRIPT.to_s, *args, stdin_data: stdin, chdir: @dir)
  end

  def requests = File.readlines(@log).map { |line| JSON.parse(line) }

  test "connect reads secrets from stdin, sends them to the resident endpoint with the conversation, and never prints them" do
    out, err, status = run_helper("connect", "ghost", "--conversation", "KekVqY", "--json", "-",
                                  stdin: { api_url: "https://blog.example.com", admin_api_key: SECRET }.to_json)

    assert status.success?, err
    request = requests.sole
    assert_equal [ "POST", "/api/v1/resident/service_connections", "Bearer resident-token" ], request.values_at("method", "path", "auth")
    assert_equal({ "provider" => "ghost", "conversation_id" => "KekVqY",
                   "credentials" => { "api_url" => "https://blog.example.com", "admin_api_key" => SECRET } }, JSON.parse(request["body"]))
    assert_match "Lume for Daniel", out
    assert_not_includes out + err, SECRET
  end

  test "fields can come from files, and a bare secret given without KEY= is never echoed" do
    File.write(File.join(@dir, "key.txt"), "#{SECRET}\n")
    _out, err, status = run_helper("connect", "ghost", "--conversation", "c1", "--field", "api_url=https://b.example", "--field", "admin_api_key=@key.txt")
    assert status.success?, err
    assert_equal SECRET, JSON.parse(requests.last["body"]).dig("credentials", "admin_api_key")

    out, err, status = run_helper("connect", "ghost", "--conversation", "c1", "--field", SECRET)
    assert_not status.success?
    assert_not_includes out + err, SECRET
  end

  test "grant, revoke and disconnect carry the conversation; disconnect says the key still works at the provider" do
    run_helper("grant", "svc_1", "mira", "--conversation", "c1")
    run_helper("revoke", "svc_1", "mira", "--conversation", "c1")
    out, _err, _status = run_helper("disconnect", "svc_1", "--conversation", "c1")

    grant, revoke, disconnect = requests
    assert_equal [ "PATCH", "/api/v1/resident/service_connections/svc_1/residents/mira" ], grant.values_at("method", "path")
    assert_equal({ "enabled" => true, "conversation_id" => "c1" }, JSON.parse(grant["body"]))
    assert_equal false, JSON.parse(revoke["body"])["enabled"]
    assert_equal [ "DELETE", "/api/v1/resident/service_connections/svc_1" ], disconnect.values_at("method", "path")
    assert_match "still valid at Ghost", out
  end

end
