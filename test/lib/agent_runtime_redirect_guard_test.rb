require "test_helper"
require "open3"
require "tmpdir"

# Python's urllib follows 301/302/303/307/308 and re-sends the Authorization
# header to whatever origin the Location names. Every agent-runtime script that
# sends a credential through urllib must refuse redirects instead. This test
# finds those scripts by what they contain, so a new helper is covered the day
# it lands, not when someone remembers to list it (#502).
class AgentRuntimeRedirectGuardTest < ActiveSupport::TestCase

  RUNTIME = Rails.root.join("agent-runtime")
  TOKEN = "synthetic-house-token-#{'f' * 24}".freeze
  REDIRECT_CODES = [ 301, 302, 303, 307, 308 ].freeze
  SKIPPED = %r{\A(docs|licenses|chaos-ref)/|\.md\z|\Atest_}

  FAKE_HOUSE = <<~PYTHON
    import json, sys
    from http.server import BaseHTTPRequestHandler, HTTPServer
    LOG = sys.argv[1]
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def handle_any(self):
            n = int(self.headers.get("Content-Length") or 0)
            if n: self.rfile.read(n)
            open(LOG, "a").write(json.dumps({"path": self.path, "auth": self.headers.get("Authorization")}) + "\\n")
            parts = self.path.split("/")
            code = int(parts[2]) if self.path.startswith("/moved/") else 200
            if code != 200:
                self.send_response(code)
                self.send_header("Location", "http://127.0.0.1:%d/elsewhere/" % self.server.server_port)
                self.send_header("Content-Length", "0"); self.end_headers(); return
            raw = b"{}"
            self.send_response(200)
            self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(raw)))
            self.end_headers(); self.wfile.write(raw)
        do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = handle_any
    server = HTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_port, flush=True)
    server.serve_forever()
  PYTHON

  # Each helper changed in #502, driven through its real request path. The
  # app URL (or the manifest endpoint) points at /moved/<code>, so the first
  # authenticated request is answered with a redirect to /elsewhere.
  HELPERS = {
    "soulshouse-post-message" => { args: %w[c1], stdin: "hello" },
    "soulshouse-model" => { args: %w[c1] },
    "soulshouse-quiet-reason" => { args: %w[c1], stdin: "busy elsewhere",
                                   env: { "SOULSHOUSE_RUNTIME_CHAT_ID" => "c1", "SOULSHOUSE_RUNTIME_RUN_ID" => "r1" } },
    "soulshouse-usage" => { args: [] },
    "soulshouse-send-telegram" => { args: %w[alice hello] },
    "soulshouse-x" => { args: %w[search redirect guards] },
    "soulshouse-youtube" => { args: %w[ask https://www.youtube.com/watch?v=dQw4w9WgXcQ what] },
    "soulshouse-reflex" => { args: %w[list] },
    "soulshouse-gws" => { args: %w[drive files list], manifest: :google_workspace },
    "soulshouse-comms" => { args: %w[chats], manifest: :whatsapp },
    "github_import_approval.py" => { python: "import github_import_approval as g; g.fetch_approval()" }
  }.freeze

  # Guarded before #502 and covered by their own tests; the static check
  # still holds them to the rule.
  GUARDED_EARLIER = %w[soulshouse-ghost soulshouse-integrations soulshouse-stone memory_client.py runtime_activity.py].freeze

  def self.credential_senders
    Dir.glob(RUNTIME.join("**/*").to_s).select { |path| File.file?(path) }.filter_map do |path|
      relative = Pathname(path).relative_path_from(RUNTIME).to_s
      next if relative.match?(SKIPPED)

      text = File.binread(path).force_encoding(Encoding::UTF_8)
      next unless text.valid_encoding?
      next unless text.include?("urllib.request") && text.match?(/["']Authorization["']/)

      relative
    end.sort
  end

  setup do
    @dir = Dir.mktmpdir
    @log = File.join(@dir, "requests.jsonl")
    File.write(File.join(@dir, "house.py"), FAKE_HOUSE)
    @server_stdin, @server_stdout, @server_thread = Open3.popen2("python3", File.join(@dir, "house.py"), @log)
    @port = @server_stdout.gets.to_i
    @base = "http://127.0.0.1:#{@port}"
  end

  teardown do
    Process.kill("TERM", @server_thread.pid) rescue nil
    @server_thread.join
    FileUtils.remove_entry(@dir)
  end

  test "finds the credential-sending scripts, including every helper named in #502" do
    senders = self.class.credential_senders

    %w[
      soulshouse-comms soulshouse-gws soulshouse-model soulshouse-post-message soulshouse-send-telegram
      soulshouse-usage soulshouse-x soulshouse-youtube github_import_approval.py soulshouse-reflex
      soulshouse-quiet-reason soulshouse-ghost soulshouse-integrations soulshouse-stone memory_client.py
      runtime_activity.py
    ].each { |name| assert_includes senders, name }
  end

  test "no script that sends a credential through urllib can follow a redirect" do
    self.class.credential_senders.each do |relative|
      text = File.read(RUNTIME.join(relative))

      assert_no_match(/urllib\.request\.urlopen\s*\(/, text, "#{relative} calls urlopen, which follows redirects")
      assert_no_match(/from\s+urllib\.request\s+import[^\n]*\burlopen\b/, text, "#{relative} imports urlopen")
      assert_match(/class\s+\w+\(\s*urllib\.request\.HTTPRedirectHandler\s*\)/, text,
                   "#{relative} sends a credential but defines no redirect-refusing handler")
      assert_match(/build_opener\(\s*\w+\s*\)/, text, "#{relative} never builds an opener with its handler")
    end
  end

  test "every credential sender is either driven end to end here or was guarded earlier" do
    assert_equal self.class.credential_senders, (HELPERS.keys + GUARDED_EARLIER).sort
  end

  test "each changed helper, through its real request path, stops at the redirect with the credential unsent onward" do
    HELPERS.each do |name, spec|
      REDIRECT_CODES.each do |code|
        File.delete(@log) if File.exist?(@log)
        out, err, status = invoke(name, spec, "#{@base}/moved/#{code}")
        label = "#{name} #{code}"

        assert_not status.success?, label
        assert_equal 1, requests.size, "#{label}: #{requests.inspect}\n#{err}"
        assert requests.first["path"].start_with?("/moved/#{code}"), label
        assert_equal "Bearer #{TOKEN}", requests.first["auth"], label
        assert_empty requests.select { |request| request["path"].start_with?("/elsewhere") }, label
        assert_match "refused to follow a redirect (#{code}) to 127.0.0.1:#{@port}", out + err, label
        assert_not_includes out + err, TOKEN, label
      end
    end
  end

  test "soulshouse-post-message refuses a redirect, says where it pointed, and does not leak the token" do
    REDIRECT_CODES.each do |code|
      File.delete(@log) if File.exist?(@log)
      out, err, status = run_helper("soulshouse-post-message", "c1", stdin: "hello", app_url: "#{@base}/moved/#{code}")

      assert_not status.success?, code
      assert_match "redirect (#{code}) to 127.0.0.1:#{@port}", out + err
      assert_equal 1, requests.size, code
      assert_empty requests.select { |request| request["path"].start_with?("/elsewhere") }, code
      assert_not_includes out + err, TOKEN
    end
  end

  test "soulshouse-model refuses a redirect without reaching the target" do
    REDIRECT_CODES.each do |code|
      File.delete(@log) if File.exist?(@log)
      _out, _err, status = run_helper("soulshouse-model", "c1", app_url: "#{@base}/moved/#{code}")

      assert_not status.success?, code
      assert_equal 1, requests.size, code
      assert_empty requests.select { |request| request["path"].start_with?("/elsewhere") }, code
    end
  end

  test "the same helpers still work when the house answers directly" do
    _out, err, status = run_helper("soulshouse-post-message", "c1", stdin: "hello", app_url: @base)

    assert status.success?, err
    assert_equal [ "Bearer #{TOKEN}" ], requests.map { |request| request["auth"] }
  end

  private
    def run_helper(name, *args, stdin: "", app_url:)
      env = { "SOULSHOUSE_APP_URL" => app_url, "SOULSHOUSE_BEARER_TOKEN" => TOKEN,
              "HELIXKIT_APP_URL" => nil, "HELIXKIT_BEARER_TOKEN" => nil,
              "SOULSHOUSE_RUNTIME_CHAT_ID" => nil, "SOULSHOUSE_RUNTIME_RUN_ID" => nil }
      Open3.capture3(env, "python3", RUNTIME.join(name).to_s, *args, stdin_data: stdin)
    end

    def invoke(name, spec, url)
      env = { "SOULSHOUSE_APP_URL" => url, "SOULSHOUSE_BEARER_TOKEN" => TOKEN,
              "HELIXKIT_APP_URL" => nil, "HELIXKIT_BEARER_TOKEN" => nil,
              "SOULSHOUSE_RUNTIME_CHAT_ID" => nil, "SOULSHOUSE_RUNTIME_RUN_ID" => nil,
              "SOULSHOUSE_SERVICES_FILE" => manifest(spec[:manifest], url), "HELIXKIT_SERVICES_FILE" => nil,
              "SOULSHOUSE_GWS_BINARY" => "/bin/false", "PYTHONPATH" => RUNTIME.to_s }.merge(spec[:env] || {})
      command = spec[:python] ? [ "python3", "-c", spec[:python] ] : [ "python3", RUNTIME.join(name).to_s, *spec[:args] ]
      Open3.capture3(env, *command, stdin_data: spec[:stdin] || "")
    end

    def manifest(provider, url)
      path = File.join(@dir, "services.yml")
      credentials = case provider
      when :google_workspace then { "access_token_endpoint" => "#{url}/api/v1/google/token" }
      when :whatsapp then { "chats_endpoint" => "#{url}/api/v1/service_connections/svc_1/comms/chats",
                            "messages_endpoint" => "#{url}/api/v1/service_connections/svc_1/comms/messages" }
      else {}
      end
      File.write(path, { "services" => [ { "connection_id" => "svc_1", "provider" => provider.to_s, "credentials" => credentials } ] }.to_yaml)
      path
    end

    def requests
      return [] unless File.exist?(@log)

      File.readlines(@log).map { |line| JSON.parse(line) }
    end

end
