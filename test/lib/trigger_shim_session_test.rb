require "test_helper"
require "tmpdir"

# Exercises trigger_shim.py's persistent-session machinery (sidecar records,
# JSONL event parsing, resume-or-fresh decision, stale-marker guard) by
# driving the Python module directly, with CHAOS_BIN pointed at a fake chaos
# script. Mirrors the harness style of trigger_shim_prompt_test.rb.
class TriggerShimSessionTest < ActiveSupport::TestCase

  test "runtime image includes the journald companion required for resume" do
    dockerfile = Rails.root.join("agent-runtime/Dockerfile").read
    entrypoint = Rails.root.join("agent-runtime/entrypoint.sh").read
    antigravity_egress_patch =
      Rails.root.join("agent-runtime/patches/chaos-antigravity-daily-cloudcode-egress.patch").read

    assert_includes dockerfile, "cargo build --release --bin chaos_journald"
    assert_includes dockerfile, "COPY --from=builder /usr/local/bin/chaos_journald /usr/local/bin/chaos_journald"
    assert_includes dockerfile, "COPY docs/runtime-instructions.md /usr/local/share/helixkit-agent/runtime-instructions.md"
    assert_includes dockerfile, "COPY docs/helixkit-api.md /usr/local/share/helixkit-agent/helixkit-api.md"
    assert_includes dockerfile, "ARG CLAUDE_CODE_VERSION=2.1.220"
    assert_includes dockerfile, "claude --version"
    assert_includes dockerfile, "ARG CHAOS_HEAD"
    refute_match(/^ARG CHAOS_HEAD=[0-9a-f]{40}$/, dockerfile)
    assert_not_includes dockerfile, "chaos-clamp-image-tool-output.patch"
    assert_includes dockerfile, "chaos-antigravity-empty-managed-config.patch"
    assert_includes dockerfile, "git apply --check /tmp/chaos-antigravity-empty-managed-config.patch"
    assert_includes dockerfile, "chaos-antigravity-daily-cloudcode-egress.patch"
    assert_includes dockerfile, "git apply --check /tmp/chaos-antigravity-daily-cloudcode-egress.patch"
    assert_includes dockerfile, "antigravity-daily-cloudcode-egress"
    assert_includes antigravity_egress_patch, '"daily-cloudcode-pa.googleapis.com"'
    assert_includes antigravity_egress_patch, '"www.googleapis.com"'
    assert_includes antigravity_egress_patch, '"lh3.googleusercontent.com"'
    assert_includes dockerfile, "ARG ANTIGRAVITY_VERSION=1.1.15"
    assert_includes dockerfile, "sha512sum -c -"
    assert_includes dockerfile, "agy --version"
    assert_includes dockerfile, 'LABEL house.souls.chaos-ref="${CHAOS_HEAD}"'
    assert_includes entrypoint, "gosu agent chaos_journald"
    assert_includes entrypoint, 'export CHAOS_JOURNALD_SOCKET="${CHAOS_JOURNALD_SOCKET:-$CHAOS_HOME/run/journald.sock}"'
    assert_includes entrypoint, 'CHAOS_JOURNALD_DB="${CHAOS_JOURNALD_DB:-$CHAOS_HOME/journal.sqlite}"'
    assert_includes entrypoint, '--db "$CHAOS_JOURNALD_DB"'
  end

  test "runtime config installs RubyLLM providers not bundled by Chaos" do
    entrypoint = Rails.root.join("agent-runtime/entrypoint.sh").read

    Agents::Sandbox::CHAOS_RUNTIME_PROVIDER_IDS.each do |provider|
      assert_includes entrypoint, "[model_providers.#{provider}]"
    end

    assert_includes entrypoint, "https://generativelanguage.googleapis.com/v1beta/openai"
    assert_includes entrypoint, "https://openrouter.ai/api/v1"
  end

  test "auth mode changes roll persistent sessions" do
    out = run_shim_python(<<~PY)
      record = {
        "schema_version": mod.SIDECAR_SCHEMA_VERSION,
        "provider": "openai",
        "model": "gpt-5",
        "auth_mode": "api_key",
        "identity_fingerprint": mod.identity_fingerprint(),
        "runtime_context_fingerprint": mod.runtime_context_fingerprint(),
      }
      print(json.dumps({
        "same": mod.roll_reason(record, "gpt-5", "openai", auth_mode="api_key"),
        "changed": mod.roll_reason(record, "gpt-5", "openai", auth_mode="oauth_account"),
      }))
    PY

    result = JSON.parse(out)
    assert_nil result["same"]
    assert_equal "auth-mode-changed", result["changed"]
  end

  test "explicit safeguard rolls and generation changes roll persistent sessions" do
    out = run_shim_python(<<~PY)
      record = {
        "schema_version": mod.SIDECAR_SCHEMA_VERSION,
        "provider": "openai",
        "model": "gpt-5",
        "auth_mode": "api_key",
        "runtime_session_generation": 2,
        "identity_fingerprint": mod.identity_fingerprint(),
        "runtime_context_fingerprint": mod.runtime_context_fingerprint(),
      }
      print(json.dumps({
        "same": mod.roll_decision(
          record, "gpt-5", "openai", runtime_session_generation=2
        )[0],
        "generation_changed": mod.roll_decision(
          record, "gpt-5", "openai", runtime_session_generation=3
        )[0],
        "safeguard": mod.roll_decision(
          record, "gpt-5", "openai",
          roll_session=True, runtime_session_generation=2
        )[0],
      }))
    PY

    result = JSON.parse(out)
    assert_nil result["same"]
    assert_equal "requested-generation-changed", result["generation_changed"]
    assert_equal "safeguard-detected", result["safeguard"]
  end

  test "API key runs preserve the original Chaos home and subscription runs use an isolated home" do
    out = run_shim_python(<<~PY)
      import types
      calls = []
      def capture_run(*args, **kwargs):
          calls.append({
            "home": kwargs["env"]["CHAOS_HOME"],
            "openai_key": kwargs["env"].get("OPENAI_API_KEY"),
          })
          return types.SimpleNamespace(stdout="", stderr="", returncode=0)
      mod.os.environ["OPENAI_API_KEY"] = "metered-key"
      mod.subprocess.run = capture_run
      mod.run_chaos("gpt-5", 5, "prompt", False, provider="openai", auth_mode="api_key")
      mod.run_chaos("gpt-5", 5, "prompt", False, provider="openai", auth_mode="oauth_account")
      print(json.dumps(calls))
    PY

    calls = JSON.parse(out)
    assert_equal File.dirname(calls.second.fetch("home")), calls.first.fetch("home")
    assert_equal "metered-key", calls.first.fetch("openai_key")
    assert calls.second.fetch("home").end_with?("/oauth-runtime")
    assert_nil calls.second.fetch("openai_key")
  end

  test "provider account commands use the isolated subscription Chaos home" do
    out = run_shim_python(<<~PY)
      import types
      calls = []
      mod.subprocess.run = lambda *args, **kwargs: (
          calls.append(kwargs["env"]["CHAOS_HOME"]) or
          types.SimpleNamespace(stdout="", stderr="Stored provider accounts: none", returncode=1)
      )
      mod._provider_account_status("openai")
      print(json.dumps(calls))
    PY

    homes = JSON.parse(out)
    assert_equal 1, homes.size
    assert homes.first.end_with?("/oauth-runtime")
  end

  test "expired auth ceremony cannot be overwritten by its monitor thread" do
    out = run_shim_python(<<~PY)
      import types
      class Process:
          def poll(self): return None
          def terminate(self): pass
      process = Process()
      mod._auth_process = process
      mod._auth_state = {
          "status": "pending",
          "provider": "openai",
          "expires_at": "2000-01-01T00:00:00+00:00",
      }
      mod.request = types.SimpleNamespace(
          headers={"Authorization": "Bearer tr_test"},
          get_json=lambda silent=True: {},
          args={"provider": "openai"},
      )
      mod.jsonify = lambda value: value
      result = mod.auth_status()
      mod._monitor_auth_process(
          types.SimpleNamespace(stderr=[], wait=lambda: 1),
          "openai",
      )
      print(json.dumps({
          "result": result,
          "state": mod._auth_state,
          "process_cleared": mod._auth_process is None,
      }))
    PY

    result = JSON.parse(out)
    assert_equal "expired", result.dig("result", "status")
    assert_equal "expired", result.dig("state", "status")
    assert_equal true, result["process_cleared"]
  end

  test "provider auth endpoints require the trigger bearer token" do
    out = run_shim_python(<<~PY)
      import types
      mod.request = types.SimpleNamespace(headers={})
      mod.abort = lambda status: (_ for _ in ()).throw(RuntimeError(str(status)))
      try:
          mod._require_shim_auth("/auth/status")
          result = "accepted"
      except RuntimeError as error:
          result = str(error)
      print(json.dumps(result))
    PY

    assert_equal "401", JSON.parse(out)
  end

  test "starting Gemini auth returns an existing usable connection without launching Antigravity" do
    out = run_shim_python(<<~PY)
      import types
      launched = []
      mod.request = types.SimpleNamespace(
          headers={"Authorization": "Bearer tr_test"},
          get_json=lambda silent=True: {"provider": "gemini"},
      )
      mod.jsonify = lambda value: value
      mod._antigravity_oauth_token_fingerprint = lambda: "existing-token"
      mod._antigravity_account_status = lambda: {
          "status": "connected",
          "provider": "gemini",
          "plan": "Google AI",
      }
      mod.subprocess.Popen = lambda *args, **kwargs: launched.append(args) or None

      result = mod.auth_start()
      print(json.dumps({
          "result": result,
          "state": mod._auth_state,
          "process_cleared": mod._auth_process is None,
          "launch_count": len(launched),
      }))
    PY

    result = JSON.parse(out)
    assert_equal "connected", result.dig("result", "status")
    assert_equal "gemini", result.dig("result", "provider")
    assert_equal "Google AI", result.dig("state", "plan")
    assert_equal true, result["process_cleared"]
    assert_equal 0, result["launch_count"]
  end

  test "slow Gemini browser handoff remains a polling ceremony instead of failing" do
    out = run_shim_python(<<~PY)
      import types
      class Process:
          stdin = None
          stdout = []
          def poll(self): return None

      class Thread:
          def __init__(self, *args, **kwargs): pass
          def start(self): pass

      process = Process()
      mod.request = types.SimpleNamespace(
          headers={"Authorization": "Bearer tr_test"},
          get_json=lambda silent=True: {"provider": "gemini"},
      )
      mod.jsonify = lambda value: value
      mod._antigravity_oauth_token_fingerprint = lambda: None
      mod.subprocess.Popen = lambda *args, **kwargs: process
      mod.threading.Thread = Thread
      mod._auth_code_ready.wait = lambda timeout: False

      body, status = mod.auth_start()
      print(json.dumps({
          "body": body,
          "status": status,
          "process_preserved": mod._auth_process is process,
      }))
    PY

    result = JSON.parse(out)
    assert_equal 202, result["status"]
    assert_equal "starting", result.dig("body", "status")
    assert_equal "gemini", result.dig("body", "provider")
    assert_equal true, result["process_preserved"]
  end

  test "polled auth state keeps the live verification URL but not a device code" do
    out = run_shim_python(<<~PY)
      mod._auth_state = {
          "status": "awaiting_code",
          "provider": "gemini",
          "verification_url": "https://accounts.example.com/live",
          "user_code": "SECRET-ONCE",
      }
      print(json.dumps(mod._public_auth_state()))
    PY

    result = JSON.parse(out)
    assert_equal "awaiting_code", result["status"]
    assert_equal "https://accounts.example.com/live", result["verification_url"]
    assert_not result.key?("user_code")
  end

  test "a second trigger for the same session is rejected" do
    out = run_shim_python(<<~PY)
      import types
      mod.request = types.SimpleNamespace(
          headers={"Authorization": "Bearer tr_test"},
          get_json=lambda silent=True: {
              "session_id": "sess-2",
              "request": "Look at the conversation",
              "persistent_session": True,
          },
      )
      mod.jsonify = lambda value: value
      lock = mod._lock_for("sess-2")
      lock.acquire()
      try:
          body, status = mod.trigger()
      finally:
          lock.release()
      print(json.dumps({"body": body, "status": status}))
    PY

    result = JSON.parse(out)
    assert_equal 409, result["status"]
    assert_equal "already_running", result.dig("body", "status")
    assert_equal "sess-2", result.dig("body", "session_id")
  end

  test "a trigger for another session can run concurrently" do
    out = run_shim_python(<<~PY)
      import types
      mod.request = types.SimpleNamespace(
          headers={"Authorization": "Bearer tr_test"},
          get_json=lambda silent=True: {
              "session_id": "sess-2",
              "request": "Look at the other conversation",
              "persistent_session": False,
          },
      )
      mod.jsonify = lambda value: value
      mod.legacy_trigger = lambda *args, **kwargs: ({"status": "ok", "session_id": args[0]}, 200)
      other_session_lock = mod._lock_for("sess-1")
      other_session_lock.acquire()
      try:
          body, status = mod.trigger()
      finally:
          other_session_lock.release()
      print(json.dumps({"body": body, "status": status}))
    PY

    result = JSON.parse(out)
    assert_equal 200, result["status"]
    assert_equal "ok", result.dig("body", "status")
    assert_equal "sess-2", result.dig("body", "session_id")
  end

  test "provider auth routes register named handlers after they are defined" do
    source = Rails.root.join("agent-runtime/trigger_shim.py").read

    {
      "/auth/capabilities" => "auth_capabilities",
      "/auth/start" => "auth_start",
      "/auth/code" => "auth_code",
      "/auth/status" => "auth_status",
      "/auth/cancel" => "auth_cancel",
      "/auth/disconnect" => "auth_disconnect"
    }.each do |path, handler|
      registration = "\"#{path}\")(#{handler})"
      assert_includes source, registration
      assert_operator source.index(registration), :>, source.index("def #{handler}")
    end

    assert_not_includes source, '"/auth/start")(lambda:'
  end

  test "subscription capabilities include Anthropic Gemini and xAI by default" do
    out = run_shim_python(<<~PY)
      print(json.dumps(list(mod.OAUTH_ACCOUNT_PROVIDERS)))
    PY

    assert_equal %w[anthropic gemini openai xai], JSON.parse(out)
  end

  test "Anthropic subscription runs enable clamp and remove the metered API key" do
    out = run_shim_python(<<~PY)
      import types
      captured = {}
      def capture_run(args, **kwargs):
          captured["args"] = args
          captured["anthropic_key"] = kwargs["env"].get("ANTHROPIC_API_KEY")
          captured["claude_config_dir"] = kwargs["env"].get("CLAUDE_CONFIG_DIR")
          return types.SimpleNamespace(stdout="", stderr="", returncode=0)
      mod.os.environ["ANTHROPIC_API_KEY"] = "metered-key"
      mod.subprocess.run = capture_run
      mod.run_chaos(
          "claude-opus-4-7", 30, "prompt", True,
          provider="anthropic", auth_mode="oauth_account",
      )
      print(json.dumps(captured))
    PY

    result = JSON.parse(out)
    args = result.fetch("args")
    assert_includes args, "clamp=true"
    assert_nil result["anthropic_key"]
    assert result.fetch("claude_config_dir").end_with?("/state/claude")
  end

  test "Gemini subscription runs select Antigravity and remove metered API keys" do
    out = run_shim_python(<<~PY)
      import types
      captured = {}
      def capture_run(args, **kwargs):
          captured["args"] = args
          captured["gemini_key"] = kwargs["env"].get("GEMINI_API_KEY")
          captured["google_key"] = kwargs["env"].get("GOOGLE_API_KEY")
          captured["agy_home"] = kwargs["env"].get("CHAOS_AGY_HOME")
          captured["agy_path"] = kwargs["env"].get("CHAOS_AGY_PATH")
          captured["home"] = kwargs["env"].get("HOME")
          return types.SimpleNamespace(stdout="", stderr="", returncode=0)
      mod.os.environ["GEMINI_API_KEY"] = "metered-gemini"
      mod.os.environ["GOOGLE_API_KEY"] = "metered-google"
      mod.subprocess.run = capture_run
      mod.run_chaos(
          "gemini-3.1-pro-low", 30, "prompt", True,
          provider="gemini", auth_mode="oauth_account",
      )
      print(json.dumps(captured))
    PY

    result = JSON.parse(out)
    args = result.fetch("args")
    assert_includes args, "clamp=true"
    assert_includes args, "clamp_backend=antigravity"
    assert_nil result["gemini_key"]
    assert_nil result["google_key"]
    assert result.fetch("agy_home").end_with?("/state/antigravity")
    assert result.fetch("agy_path").end_with?("/fake-agy")
    assert_not_equal result.fetch("agy_home"), result.fetch("home")
  end

  test "Anthropic browser code is written only to the live login process" do
    out = run_shim_python(<<~PY)
      import io, types
      class Process:
          def __init__(self):
              self.stdin = io.StringIO()
          def poll(self): return None
      process = Process()
      mod._auth_process = process
      mod._auth_state = {"status": "awaiting_code", "provider": "anthropic"}
      mod.request = types.SimpleNamespace(
          headers={"Authorization": "Bearer tr_test"},
          get_json=lambda silent=True: {
              "provider": "anthropic",
              "code": "http://localhost:54545/callback?code=secret-once&state=browser-state",
          },
      )
      mod.jsonify = lambda value: value
      result = mod.auth_code()
      print(json.dumps({
          "result": result,
          "stdin": process.stdin.getvalue(),
          "state": mod._auth_state,
      }))
    PY

    result = JSON.parse(out)
    assert_equal "finalizing", result.dig("result", "status")
    assert_equal "secret-once\n", result["stdin"]
    assert_not_includes result.fetch("state").to_json, "secret-once"
    assert_not_includes result["stdin"], "browser-state"
  end

  test "Gemini browser code is written only to the live Antigravity process" do
    out = run_shim_python(<<~PY)
      import io, types
      class Process:
          def __init__(self):
              self.stdin = io.StringIO()
          def poll(self): return None
      process = Process()
      mod._auth_process = process
      mod._auth_state = {"status": "awaiting_code", "provider": "gemini"}
      mod.request = types.SimpleNamespace(
          headers={"Authorization": "Bearer tr_test"},
          get_json=lambda silent=True: {
              "provider": "gemini",
              "code": "one-time-antigravity-code",
          },
      )
      mod.jsonify = lambda value: value
      result = mod.auth_code()
      print(json.dumps({
          "result": result,
          "stdin": process.stdin.getvalue(),
          "state": mod._auth_state,
      }))
    PY

    result = JSON.parse(out)
    assert_equal "finalizing", result.dig("result", "status")
    assert_equal "one-time-antigravity-code\r", result["stdin"]
    assert_not_includes result.fetch("state").to_json, "one-time-antigravity-code"
  end

  test "Gemini login uses a PTY without echoing the browser code" do
    out = run_shim_python(<<~PY)
      print(json.dumps({
          "command": mod._antigravity_login_command(),
          "path": mod._antigravity_cli_env()["PATH"],
          "url_path": mod._antigravity_cli_env()["CHAOS_AGY_LOGIN_URL_PATH"],
      }))
    PY

    result = JSON.parse(out)
    command = result.fetch("command")
    assert command.first.end_with?("/script")
    assert_equal "-qefc", command[1]
    assert_match %r{\Astty -echo; exec .*/fake-agy\z}, command[2]
    assert_equal "/dev/null", command[3]
    assert result.fetch("path").start_with?("/usr/local/libexec/helixkit-antigravity-login:")
    assert result.fetch("url_path").end_with?("/state/antigravity/.login-url")
  end

  test "Gemini login captures and removes the browser helper URL" do
    out = run_shim_python(<<~PY)
      import types
      process = types.SimpleNamespace(poll=lambda: None)
      mod._auth_process = process
      mod._auth_state = {"status": "starting", "provider": "gemini"}
      path = mod._antigravity_login_url_path()
      path.parent.mkdir(parents=True, exist_ok=True)
      path.write_text("https://accounts.google.com/o/oauth2/auth?state=private\\n")
      mod._monitor_antigravity_login_url(process)
      print(json.dumps({
          "state": mod._auth_state,
          "path_exists": path.exists(),
      }))
    PY

    result = JSON.parse(out)
    assert_equal "awaiting_code", result.dig("state", "status")
    assert_equal "https://accounts.google.com/o/oauth2/auth?state=private",
                 result.dig("state", "verification_url")
    assert_equal false, result.fetch("path_exists")
  end

  test "Gemini login does not delete a URL created after a missed read" do
    out = run_shim_python(<<~PY)
      class Process:
          def __init__(self):
              self.polls = 0
          def poll(self):
              self.polls += 1
              return None if self.polls < 4 else 0

      process = Process()
      mod._auth_process = process
      mod._auth_state = {"status": "starting", "provider": "gemini"}
      mod.time.sleep = lambda _seconds: None
      path = mod._antigravity_login_url_path()
      path.parent.mkdir(parents=True, exist_ok=True)
      path.unlink(missing_ok=True)
      path_type = type(path)
      original_read_text = path_type.read_text
      first_read = True

      def racing_read_text(self, *args, **kwargs):
          global first_read
          if first_read and self == path:
              first_read = False
              self.write_text("https://accounts.google.com/o/oauth2/auth?state=raced\\n")
              raise FileNotFoundError(self)
          return original_read_text(self, *args, **kwargs)

      path_type.read_text = racing_read_text
      try:
          mod._monitor_antigravity_login_url(process)
      finally:
          path_type.read_text = original_read_text

      print(json.dumps({
          "state": mod._auth_state,
          "path_exists": path.exists(),
      }))
    PY

    result = JSON.parse(out)
    assert_equal "awaiting_code", result.dig("state", "status")
    assert_equal "https://accounts.google.com/o/oauth2/auth?state=raced",
                 result.dig("state", "verification_url")
    assert_equal false, result.fetch("path_exists")
  end

  test "Gemini login stops its interactive TUI after credentials are written" do
    out = run_shim_python(<<~PY)
      class Process:
          def __init__(self):
              self.terminated = False
          def poll(self):
              return 0 if self.terminated else None
          def terminate(self):
              self.terminated = True

      process = Process()
      mod._auth_process = process
      mod._auth_state = {"status": "finalizing", "provider": "gemini"}
      token_path = mod._antigravity_oauth_token_path()
      token_path.parent.mkdir(parents=True, exist_ok=True)
      token_path.unlink(missing_ok=True)
      sleeps = 0

      def sleep(_seconds):
          global sleeps
          sleeps += 1
          if sleeps == 1:
              token_path.write_text("oauth-token")

      times = iter((1.0, 1.3))
      mod.time.sleep = sleep
      mod.time.monotonic = lambda: next(times)
      mod._monitor_antigravity_credentials(process, None)
      print(json.dumps({
          "terminated": process.terminated,
          "token_fingerprint": mod._antigravity_oauth_token_fingerprint(),
      }))
    PY

    result = JSON.parse(out)
    assert_equal true, result.fetch("terminated")
    assert result.fetch("token_fingerprint").present?
  end

  test "Gemini login reports connected when the credential watcher stops its TUI" do
    out = run_shim_python(<<~PY)
      class Process:
          stdout = ()
          def wait(self): return -15

      process = Process()
      mod._auth_process = process
      mod._auth_state = {"status": "finalizing", "provider": "gemini"}
      token_path = mod._antigravity_oauth_token_path()
      token_path.parent.mkdir(parents=True, exist_ok=True)
      token_path.write_text("oauth-token")
      mod._provider_account_status = lambda provider: {
          "status": "connected",
          "provider": provider,
          "plan": "Google AI",
      }
      mod._monitor_auth_process(process, "gemini", None)
      print(json.dumps({
          "state": mod._auth_state,
          "process_cleared": mod._auth_process is None,
      }))
    PY

    result = JSON.parse(out)
    assert_equal "connected", result.dig("state", "status")
    assert_equal "Google AI", result.dig("state", "plan")
    assert_equal true, result.fetch("process_cleared")
  end

  test "Gemini login advances only the non-secret onboarding selector" do
    out = run_shim_python(<<~PY)
      import io
      class Process:
          def __init__(self):
              self.stdin = io.StringIO()
          def poll(self): return None
      process = Process()
      mod.time.sleep = lambda _seconds: None
      mod._advance_antigravity_login(process)
      print(json.dumps(process.stdin.getvalue()))
    PY

    assert_equal "\r", JSON.parse(out)
  end

  test "Anthropic login URL parsing stops at OSC-8 terminal hyperlink controls" do
    out = run_shim_python(<<~'PY')
      line = (
          "Visit: \x1b]8;;https://claude.com/oauth?state=hidden\x07"
          "https://claude.com/oauth?state=visible\x1b]8;;\x07"
      )
      print(json.dumps(mod._first_http_url(line)))
    PY

    assert_equal "https://claude.com/oauth?state=hidden", JSON.parse(out)
  end

  test "provider status parsing returns display metadata without token data" do
    out = run_shim_python(<<~PY)
      import types
      mod.subprocess.run = lambda *args, **kwargs: types.SimpleNamespace(
          stdout="",
          stderr="Stored provider accounts:\\n  - OpenAI: ChatGPT account (subscriber@example.com)\\n",
          returncode=0,
      )
      print(json.dumps(mod._provider_account_status("openai")))
    PY

    result = JSON.parse(out)
    assert_equal "connected", result["status"]
    assert_equal "subscriber@example.com", result["email"]
    assert_equal %w[email provider status], result.keys.sort
  end

  test "provider status parsing recognizes xAI subscription accounts" do
    out = run_shim_python(<<~PY)
      import types
      mod.subprocess.run = lambda *args, **kwargs: types.SimpleNamespace(
          stdout="",
          stderr="Stored provider accounts:\\n  - xAI: xAI account (subscriber@example.com)\\n",
          returncode=0,
      )
      print(json.dumps(mod._provider_account_status("xai")))
    PY

    result = JSON.parse(out)
    assert_equal "connected", result["status"]
    assert_equal "xai", result["provider"]
    assert_equal "subscriber@example.com", result["email"]
  end

  test "provider status parsing recognizes Claude subscription auth JSON" do
    out = run_shim_python(<<~PY)
      import types
      mod._claude_available = lambda: True
      mod.subprocess.run = lambda *args, **kwargs: types.SimpleNamespace(
          stdout=json.dumps({
              "loggedIn": True,
              "authMethod": "claude.ai",
              "apiProvider": "firstParty",
              "email": "subscriber@example.com",
          }),
          stderr="",
          returncode=0,
      )
      print(json.dumps(mod._provider_account_status("anthropic")))
    PY

    result = JSON.parse(out)
    assert_equal "connected", result["status"]
    assert_equal "anthropic", result["provider"]
    assert_equal "subscriber@example.com", result["email"]
    assert_not_includes result.to_json, "token"
  end

  test "provider status recognizes an authenticated Antigravity CLI without exposing credentials" do
    out = run_shim_python(<<~PY)
      import types
      mod._agy_available = lambda: True
      mod.subprocess.run = lambda *args, **kwargs: types.SimpleNamespace(
          stdout="gemini-3.1-pro-low\\ngemini-3-flash\\n",
          stderr="",
          returncode=0,
      )
      print(json.dumps(mod._provider_account_status("gemini")))
    PY

    result = JSON.parse(out)
    assert_equal "connected", result["status"]
    assert_equal "gemini", result["provider"]
    assert_equal "Google AI", result["plan"]
    assert_not_includes result.to_json.downcase, "token"
  end

  test "provider status parsing does not mistake Not logged in text for a connection" do
    out = run_shim_python(<<~PY)
      import types
      mod._claude_available = lambda: True
      mod.subprocess.run = lambda *args, **kwargs: types.SimpleNamespace(
          stdout="Not logged in",
          stderr="",
          returncode=0,
      )
      print(json.dumps(mod._provider_account_status("anthropic")))
    PY

    result = JSON.parse(out)
    assert_equal "none", result["status"]
    assert_equal "anthropic", result["provider"]
  end

  test "provider status parsing honors an explicit logged-out JSON status" do
    out = run_shim_python(<<~PY)
      import types
      mod._claude_available = lambda: True
      mod.subprocess.run = lambda *args, **kwargs: types.SimpleNamespace(
          stdout=json.dumps({
              "loggedIn": False,
              "email": "stale@example.com",
          }),
          stderr="",
          returncode=0,
      )
      print(json.dumps(mod._provider_account_status("anthropic")))
    PY

    result = JSON.parse(out)
    assert_equal "none", result["status"]
    assert_equal "anthropic", result["provider"]
    assert_not_includes result.to_json, "stale@example.com"
  end

  test "entrypoint does not rewrite historical runtime documentation in identity" do
    entrypoint = Rails.root.join("agent-runtime/entrypoint.sh").read

    assert_not_includes entrypoint, "identity/runtime-instructions.md"
    assert_not_includes entrypoint, "identity/helixkit-api.md"
    assert_not_includes entrypoint, "runtime-instructions.md.new"
    assert_includes entrypoint, "identity/automation/stop_journal_reflex.py"
  end

  test "parse_events keeps old cumulative usage explicitly legacy" do
    out = run_shim_python(<<~PY)
      events = "\\n".join([
        '{"type":"process.started","process_id":"pid-123"}',
        'garbage line',
        '{"type":"turn.completed","usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":7}}',
        '{"type":"item.completed","item":{"id":"1","type":"agent_message","text":"hello"}}',
        '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":140,"output_tokens":3}}',
      ])
      parsed = mod.parse_events(events)
      print(json.dumps(parsed))
    PY

    parsed = JSON.parse(out)
    assert_equal "pid-123", parsed["process_id"]
    assert_equal 10, parsed["input_tokens"]
    assert_equal 140, parsed["cached_input_tokens"]
    assert_equal 3, parsed["output_tokens"]
    assert_equal "legacy", parsed["telemetry_status"]
    assert_nil parsed["usage"]
    assert_equal [ "hello" ], parsed["agent_messages"]
  end

  test "parse_events preserves versioned invocation usage and unknown values" do
    out = run_shim_python(<<~PY)
      events = "\\n".join([
        '{"type":"process.started","process_id":"pid-123"}',
        '{"type":"turn.completed","telemetry_schema_version":1,"usage":' +
          '{"scope":"invocation","input_tokens":100,"uncached_input_tokens":10,' +
          '"cache_creation_input_tokens":20,"cache_read_input_tokens":70,' +
          '"output_tokens":7,"provider_request_count":2}}',
      ])
      print(json.dumps(mod.parse_events(events)))
    PY

    parsed = JSON.parse(out)
    assert_equal "detailed", parsed["telemetry_status"]
    assert_equal 1, parsed["telemetry_schema_version"]
    assert_equal "invocation", parsed.dig("usage", "scope")
    assert_equal 20, parsed.dig("usage", "cache_creation_input_tokens")
    assert_equal 70, parsed.dig("usage", "cache_read_input_tokens")
    assert_equal 2, parsed.dig("usage", "provider_request_count")
    assert_nil parsed.dig("usage", "reasoning_output_tokens")
  end

  test "unversioned additive Chaos counters remain available for compatibility subtraction" do
    out = run_shim_python(<<~PY)
      events = mod.parse_events(
        '{"type":"turn.completed","usage":' +
        '{"input_tokens":1000,"cache_creation_input_tokens":40,"cached_input_tokens":700,' +
        '"output_tokens":20,"reasoning_output_tokens":4,"provider_request_count":5}}'
      )
      record = {
        "cumulative_input_tokens": 900,
        "cumulative_cache_creation_input_tokens": 25,
        "cumulative_cached_input_tokens": 650,
        "cumulative_cache_read_input_tokens": 650,
        "cumulative_output_tokens": 18,
        "cumulative_reasoning_output_tokens": 3,
        "cumulative_provider_request_count": 4,
      }
      print(json.dumps({
        "parsed": events["legacy_cumulative_usage"],
        "invocation": mod.usage_since(record, events),
      }))
    PY

    result = JSON.parse(out)
    assert_equal 40, result.dig("parsed", "cache_creation_input_tokens")
    assert_equal 700, result.dig("parsed", "cache_read_input_tokens")
    assert_nil result.dig("parsed", "uncached_input_tokens")
    assert_equal 15, result.dig("invocation", "cache_creation_input_tokens")
    assert_equal 50, result.dig("invocation", "cache_read_input_tokens")
    assert_equal 1, result.dig("invocation", "provider_request_count")
    assert_equal 1, result.dig("invocation", "reasoning_output_tokens")
  end

  test "parse_events selects the final versioned completion and keeps cumulative diagnostics separate" do
    out = run_shim_python(<<~PY)
      events = "\\n".join([
        '{"type":"turn.completed","telemetry_schema_version":1,"usage":' +
          '{"scope":"invocation","input_tokens":10,"output_tokens":1}}',
        '{"type":"invocation.completed","telemetry_schema_version":1,"usage":' +
          '{"scope":"invocation","input_tokens":20,"uncached_input_tokens":0,' +
          '"cache_creation_input_tokens":5,"cache_read_input_tokens":15,"output_tokens":2,' +
          '"provider_request_count":3},"session_usage":' +
          '{"scope":"process_cumulative","input_tokens":200,"output_tokens":20}}',
      ])
      print(json.dumps(mod.parse_events(events)))
    PY

    parsed = JSON.parse(out)
    assert_equal 20, parsed.dig("usage", "input_tokens")
    assert_equal 0, parsed.dig("usage", "uncached_input_tokens")
    assert_equal 3, parsed.dig("usage", "provider_request_count")
    assert_equal "process_cumulative", parsed.dig("session_usage", "scope")
    assert_equal 200, parsed.dig("session_usage", "input_tokens")
  end

  test "parse_events rejects unsupported telemetry versions without inventing usage" do
    out = run_shim_python(<<~PY)
      event = '{"type":"turn.completed","telemetry_schema_version":99,"usage":' + \
        '{"scope":"invocation","input_tokens":100}}'
      print(json.dumps(mod.parse_events(event)))
    PY

    parsed = JSON.parse(out)
    assert_equal "unsupported", parsed["telemetry_status"]
    assert_equal 99, parsed["unsupported_telemetry_schema_version"]
    assert_nil parsed["usage"]
  end

  test "the final completion event replaces earlier detailed telemetry" do
    out = run_shim_python(<<~PY)
      events = "\\n".join([
        '{"type":"turn.completed","telemetry_schema_version":1,"usage":' +
          '{"scope":"invocation","input_tokens":100}}',
        '{"type":"invocation.completed","telemetry_schema_version":99,"usage":' +
          '{"scope":"invocation","input_tokens":200}}',
      ])
      print(json.dumps(mod.parse_events(events)))
    PY

    parsed = JSON.parse(out)
    assert_equal "unsupported", parsed["telemetry_status"]
    assert_equal 99, parsed["telemetry_schema_version"]
    assert_equal 99, parsed["unsupported_telemetry_schema_version"]
    assert_nil parsed["usage"]
    assert_nil parsed["session_usage"]
  end

  test "failed versioned invocations are explicitly incomplete" do
    out = run_shim_python(<<~PY)
      events = mod.parse_events(
        '{"type":"turn.completed","telemetry_schema_version":1,"usage":' +
        '{"scope":"invocation","input_tokens":100,"complete":true}}'
      )
      print(json.dumps({
        "parsed": events["usage"],
        "successful": mod.response_invocation_usage(events, 0),
        "failed": mod.response_invocation_usage(events, 1),
      }))
    PY

    result = JSON.parse(out)
    assert_equal true, result.dig("parsed", "complete")
    assert_equal true, result.dig("successful", "complete")
    assert_equal false, result.dig("failed", "complete")
  end

  test "session records use content hashes and name changed identity files" do
    out = run_shim_python(<<~PY)
      events = mod.parse_events('{"type":"process.started","process_id":"pid-abc"}\\n' +
        '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}')
      legacy_runtime = mod.AGENT_IDENTITY_PATH / "runtime-instructions.md"
      legacy_runtime.write_text("OLD PLATFORM COPY\\n")
      mod.save_session_record("sess-1", "claude-opus-4-7", events, provider="anthropic")
      record = mod.load_session_record("sess-1")
      checks = {
        "loaded_pid": record["chaos_process_id"],
        "schema_version": record["schema_version"],
        "cumulative_input_tokens": record["cumulative_input_tokens"],
        "soul_fingerprint": record["identity_fingerprint"]["soul.md"],
        "runtime_fingerprint": record["runtime_context_fingerprint"],
        "same_model": mod.roll_reason(record, "claude-opus-4-7", "anthropic"),
        "other_model": mod.roll_reason(record, "claude-haiku-4-5", "anthropic"),
        "other_provider": mod.roll_reason(record, "claude-opus-4-7", "openrouter"),
      }

      # A same-content touch must not roll a live session.
      import os
      soul = mod.AGENT_IDENTITY_PATH / "soul.md"
      os.utime(soul, ns=(soul.stat().st_atime_ns, soul.stat().st_mtime_ns + 1_000_000))
      checks["same_content_touch"] = mod.roll_reason(record, "claude-opus-4-7", "anthropic")
      legacy_runtime.write_text("MY HISTORICAL NOTES\\n")
      checks["legacy_runtime_edit"] = mod.roll_reason(record, "claude-opus-4-7", "anthropic")
      original_runtime_context = mod.runtime_context
      mod.runtime_context = lambda: original_runtime_context() + "\\nWRAPPER CHANGED"
      checks["runtime_changed"] = mod.roll_reason(record, "claude-opus-4-7", "anthropic")
      mod.runtime_context = original_runtime_context
      soul.write_text("SOUL CHANGED\\n")
      checks["identity_changed"], checks["changed_files"] = mod.roll_decision(
          record, "claude-opus-4-7", "anthropic"
      )

      mod.retire_session_record("sess-1", reason="test")
      checks["after_retire"] = mod.load_session_record("sess-1")
      print(json.dumps(checks))
    PY

    checks = JSON.parse(out)
    assert_equal "pid-abc", checks["loaded_pid"]
    assert_equal 3, checks["schema_version"]
    assert_equal 50, checks["cumulative_input_tokens"]
    assert_equal "SOUL FIRST\n".bytesize, checks.dig("soul_fingerprint", "bytes")
    assert_match(/\A[0-9a-f]{64}\z/, checks.dig("soul_fingerprint", "sha256"))
    assert_match(/\A[0-9a-f]{64}\z/, checks.dig("runtime_fingerprint", "sha256"))
    assert_nil checks["same_model"]
    assert_equal "model-changed", checks["other_model"]
    assert_equal "provider-changed", checks["other_provider"]
    assert_nil checks["same_content_touch"]
    assert_nil checks["legacy_runtime_edit"]
    assert_equal "runtime-context-changed", checks["runtime_changed"]
    assert_equal "identity-changed", checks["identity_changed"]
    assert_equal [ "soul.md" ], checks["changed_files"]
    assert_nil checks["after_retire"]
  end

  test "sidecar schema and trigger sequence upgrades are forward compatible" do
    out = run_shim_python(<<~PY)
      current_fingerprint = mod.identity_fingerprint()
      version_one = {
        "schema_version": 1,
        "provider": "anthropic",
        "model": "claude-opus-4-7",
        "identity_fingerprint": current_fingerprint,
        "runtime_context_fingerprint": mod.runtime_context_fingerprint(),
      }
      future = {**version_one, "schema_version": 99}
      malformed = {**version_one, "schema_version": "future"}
      print(json.dumps({
        "version_one_roll": mod.roll_reason(version_one, "claude-opus-4-7", "anthropic"),
        "future_roll": mod.roll_reason(future, "claude-opus-4-7", "anthropic"),
        "malformed_roll": mod.roll_reason(malformed, "claude-opus-4-7", "anthropic"),
        "missing_sequence": mod.next_trigger_sequence(version_one),
        "malformed_sequence": mod.next_trigger_sequence({"trigger_sequence": "unknown"}),
        "existing_sequence": mod.next_trigger_sequence({"trigger_sequence": 7}),
      }))
    PY

    result = JSON.parse(out)
    assert_nil result["version_one_roll"]
    assert_equal "sidecar-schema-unsupported", result["future_roll"]
    assert_equal "sidecar-schema-unsupported", result["malformed_roll"]
    assert_equal 1, result["missing_sequence"]
    assert_equal 1, result["malformed_sequence"]
    assert_equal 8, result["existing_sequence"]
  end

  test "legacy sidecars without runtime context take one fresh roll" do
    out = run_shim_python(<<~PY)
      record = {
        "schema_version": 2,
        "provider": "anthropic",
        "model": "claude-opus-4-7",
        "identity_fingerprint": mod.identity_fingerprint(),
      }
      print(json.dumps({
        "reason": mod.roll_reason(record, "claude-opus-4-7", "anthropic"),
      }))
    PY

    assert_equal "runtime-context-changed", JSON.parse(out)["reason"]
  end

  test "usage_since handles cumulative counter resets" do
    out = run_shim_python(<<~PY)
      record = {
        "cumulative_input_tokens": 500,
        "cumulative_cached_input_tokens": 200,
        "cumulative_output_tokens": 50,
      }
      events = {"input_tokens": 80, "cached_input_tokens": 30, "output_tokens": 9}
      print(json.dumps(mod.usage_since(record, events)))
    PY

    assert_equal(
      { "input_tokens" => 80, "cached_input_tokens" => 30, "output_tokens" => 9 },
      JSON.parse(out)
    )
  end

  test "run_chaos uses the current headless execution flag" do
    out = run_shim_python(<<~PY)
      captured = {}
      def fake_run(args, **kwargs):
          captured["args"] = args
          return mod.subprocess.CompletedProcess(args, 0, "", "")
      mod.subprocess.run = fake_run
      mod.run_chaos(
          "gpt-5.2", 30, "REQUEST", True,
          provider="openai", reasoning_effort="high"
      )
      print(json.dumps(captured))
    PY

    args = JSON.parse(out).fetch("args")
    assert_includes args, "--headless"
    assert_equal "openai", args[args.index("--provider") + 1]
    assert_equal "gpt-5.2", args[args.index("-m") + 1]
    assert_includes args, 'model_reasoning_effort="high"'
    assert_not_includes args, "--dangerously-bypass-approvals-and-sandbox"
  end

  test "trigger shim accepts every reasoning effort understood by Chaos" do
    out = run_shim_python(<<~PY)
      print(json.dumps(list(mod.SUPPORTED_REASONING_EFFORTS)))
    PY

    assert_equal(
      %w[none minimal low medium high xhigh max ultra],
      JSON.parse(out)
    )
  end

  test "non-persistent triggers use JSON output and record a legacy fresh lifecycle" do
    out = run_shim_python(<<~PY, fake_chaos: :echo_resumed_pid)
      captured = {}
      original_run_chaos = mod.run_chaos
      def capture_run(
          model, timeout_secs, prompt_text, json_output,
          resume_id=None, provider=None, reasoning_effort=None
      ):
          captured["json_output"] = json_output
          return original_run_chaos(
              model, timeout_secs, prompt_text, json_output,
              resume_id=resume_id, provider=provider,
              reasoning_effort=reasoning_effort
          )
      mod.run_chaos = capture_run
      response, code = mod.legacy_trigger(
          "legacy-session", "REQUEST FULL", "claude-opus-4-7", 30
      )
      print(json.dumps({"response": response, "code": code, "captured": captured}))
    PY

    result = JSON.parse(out)
    response = result["response"]
    assert_equal 200, result["code"]
    assert_equal true, result.dig("captured", "json_output")
    assert_equal "legacy_fresh", response.dig("telemetry", "session", "outcome")
    assert_equal false, response.dig("telemetry", "session", "persistent_requested")
    assert_equal false, response.dig("telemetry", "session", "mapping_found")
    assert_equal "full", response.dig("telemetry", "prompt", "mode")
    assert_equal 120, response.dig("telemetry", "usage", "input_tokens")
    assert response["chaos_session_id"].present?
  end

  test "first persistent trigger goes fresh, second resumes the mapped session" do
    out = run_shim_python(<<~PY, fake_chaos: :echo_resumed_pid)
      first, code1 = mod.persistent_trigger("sess-2", "REQUEST FULL", None, "claude-opus-4-7", 30)
      second, code2 = mod.persistent_trigger("sess-2", "REQUEST FULL 2", "DELTA ONLY", "claude-opus-4-7", 30)
      print(json.dumps({"first": first, "code1": code1, "second": second, "code2": code2}))
    PY

    result = JSON.parse(out)
    first, second = result["first"], result["second"]

    assert_equal 200, result["code1"]
    assert_equal false, first["session_resumed"]
    assert first["chaos_session_id"].present?
    assert_includes first["full_invocation_text"], "SOUL FIRST", "fresh turn must carry identity"
    assert_includes first["full_invocation_text"], "REQUEST FULL"
    assert_equal 1, first.dig("telemetry", "schema_version")
    assert_equal "fake-chaos 0.0.1", first.dig("telemetry", "runtime", "chaos_version")
    assert_equal "anthropic", first.dig("telemetry", "runtime", "provider")
    assert_equal "claude-opus-4-7", first.dig("telemetry", "runtime", "model")
    assert_equal "1h", first.dig("telemetry", "runtime", "cache_ttl")
    assert_equal "fresh", first.dig("telemetry", "session", "outcome")
    assert_equal "full", first.dig("telemetry", "prompt", "mode")
    assert_operator first.dig("telemetry", "prompt", "full_prompt_bytes"), :>, 0
    assert_equal 120, first.dig("telemetry", "usage", "input_tokens")
    assert_equal 30, first.dig("telemetry", "usage", "cache_read_input_tokens")
    assert_equal 1, first.dig("telemetry", "usage", "provider_request_count")
    assert_equal "process_cumulative", first.dig("telemetry", "session_usage", "scope")

    assert_equal 200, result["code2"]
    assert_equal true, second["session_resumed"], "second trigger should resume"
    assert_equal first["chaos_session_id"], second["chaos_session_id"]
    assert_equal "DELTA ONLY", second["full_invocation_text"], "resumed turn sends the delta, unwrapped"
    assert_equal first["usage"], second["usage"], "Chaos reports each invocation directly"
    assert_equal "resumed", second.dig("telemetry", "session", "outcome")
    assert_equal true, second.dig("telemetry", "session", "mapping_found")
    assert_equal true, second.dig("telemetry", "session", "resume_attempted")
    assert_equal 2, second.dig("telemetry", "session", "trigger_sequence")
    assert_equal "delta", second.dig("telemetry", "prompt", "mode")
    assert_equal "DELTA ONLY".bytesize, second.dig("telemetry", "prompt", "selected_prompt_bytes")
    assert_nil second.dig("telemetry", "prompt", "full_prompt_bytes")
    assert_equal({}, second.dig("telemetry", "prompt", "components"))
  end

  test "explicit safeguard roll is reported even when no sidecar mapping exists" do
    out = run_shim_python(<<~PY, fake_chaos: :echo_resumed_pid)
      response, code = mod.persistent_trigger(
          "sess-safeguard-no-record", "REQUEST FULL", None,
          "claude-opus-4-7", 30, roll_session=True
      )
      print(json.dumps({"response": response, "code": code}))
    PY

    result = JSON.parse(out)
    assert_equal 200, result["code"]
    assert_equal "fresh", result.dig("response", "telemetry", "session", "outcome")
    assert_equal "safeguard-detected", result.dig("response", "telemetry", "session", "roll_reason")
    assert_equal "safeguard-detected", result.dig("response", "session_roll_reason")
  end

  test "successful resume does not rebuild the full prompt or reread journals" do
    out = run_shim_python(<<~PY, fake_chaos: :echo_resumed_pid)
      first, _ = mod.persistent_trigger("sess-no-reread", "REQUEST ONE", None, "claude-opus-4-7", 30)

      def fail_if_journals_are_read():
          raise AssertionError("successful resume rebuilt memory context")
      mod.memory_context = fail_if_journals_are_read

      second, code = mod.persistent_trigger(
          "sess-no-reread", "REQUEST TWO", "DELTA ONLY", "claude-opus-4-7", 30
      )
      print(json.dumps({"first": first, "second": second, "code": code}))
    PY

    result = JSON.parse(out)
    assert_equal 200, result["code"]
    assert_equal true, result.dig("second", "session_resumed")
    assert_equal "DELTA ONLY", result.dig("second", "full_invocation_text")
    assert_nil result.dig("second", "telemetry", "prompt", "full_prompt_bytes")
  end

  test "stale resume falls back to one fresh full-identity retry" do
    out = run_shim_python(<<~PY, fake_chaos: :always_fresh_pid)
      first, _ = mod.persistent_trigger("sess-3", "REQUEST ONE", None, "claude-opus-4-7", 30)
      # Fake chaos mints a NEW pid on resume too, so the shim must detect the
      # stale marker and retry fresh with full identity.
      second, code2 = mod.persistent_trigger("sess-3", "REQUEST TWO", "DELTA ONLY", "claude-opus-4-7", 30)
      print(json.dumps({"first": first, "second": second, "code2": code2}))
    PY

    result = JSON.parse(out)
    second = result["second"]

    assert_equal 200, result["code2"]
    assert_equal false, second["session_resumed"]
    assert_equal true, second["fresh_fallback"]
    assert_equal "resume-failed", second["session_roll_reason"]
    assert_equal "fresh_fallback", second.dig("telemetry", "session", "outcome")
    assert_equal "trigger", second.dig("telemetry", "usage", "scope")
    assert_equal 240, second.dig("telemetry", "usage", "input_tokens")
    assert_equal 2, second.dig("telemetry", "usage", "provider_request_count")
    assert_includes second["full_invocation_text"], "SOUL FIRST", "fallback must re-inject identity"
    assert_includes second["full_invocation_text"], "REQUEST TWO"
    assert_not_includes second["full_invocation_text"], "DELTA ONLY", "the fallback retry must use the full prompt"
  end

  test "resume timeout retires the ambiguous session mapping" do
    out = run_shim_python(<<~PY)
      events = mod.parse_events('{"type":"process.started","process_id":"pid-timeout"}\\n' +
        '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}')
      mod.save_session_record("sess-timeout", "claude-opus-4-7", events)

      def time_out(*args, **kwargs):
          raise mod.subprocess.TimeoutExpired(cmd="chaos", timeout=30)
      mod.run_chaos = time_out

      response, code = mod.persistent_trigger(
          "sess-timeout", "REQUEST FULL", "DELTA ONLY", "claude-opus-4-7", 30
      )
      print(json.dumps({
          "response": response,
          "code": code,
          "record": mod.load_session_record("sess-timeout"),
      }))
    PY

    result = JSON.parse(out)
    assert_equal 504, result["code"]
    assert_equal "timeout", result.dig("response", "status")
    assert_equal "resume_timeout", result.dig("response", "telemetry", "session", "outcome")
    assert_equal "incomplete", result.dig("response", "telemetry", "chaos_telemetry_status")
    assert_nil result["record"]
  end

  test "timeout salvages partial versioned usage and marks it incomplete" do
    out = run_shim_python(<<~PY)
      initial = mod.parse_events(
        '{"type":"process.started","process_id":"pid-partial"}\\n' +
        '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":0,"output_tokens":5}}'
      )
      mod.save_session_record("sess-partial", "claude-opus-4-7", initial)
      partial = "\\n".join([
        '{"type":"process.started","process_id":"pid-partial"}',
        '{"type":"invocation.completed","telemetry_schema_version":1,"usage":' +
          '{"scope":"invocation","input_tokens":90,"uncached_input_tokens":10,' +
          '"cache_creation_input_tokens":20,"cache_read_input_tokens":60,' +
          '"output_tokens":8,"provider_request_count":2}}',
      ])

      def time_out(*args, **kwargs):
          raise mod.subprocess.TimeoutExpired(
              cmd="chaos", timeout=30, output=partial, stderr="partial stderr"
          )
      mod.run_chaos = time_out

      response, code = mod.persistent_trigger(
          "sess-partial", "REQUEST FULL", "DELTA ONLY", "claude-opus-4-7", 30
      )
      print(json.dumps({
          "response": response,
          "code": code,
          "record": mod.load_session_record("sess-partial"),
      }))
    PY

    result = JSON.parse(out)
    response = result["response"]
    assert_equal 504, result["code"]
    assert_equal false, response["session_resumed"]
    assert_equal 90, response.dig("telemetry", "usage", "input_tokens")
    assert_equal 20, response.dig("telemetry", "usage", "cache_creation_input_tokens")
    assert_equal false, response.dig("telemetry", "usage", "complete")
    assert_equal false, response.dig("usage", "complete")
    assert_equal "partial stderr", response["stderr"]
    assert_equal "incomplete", response.dig("telemetry", "chaos_telemetry_status")
    assert_nil result["record"]
  end

  test "model change rolls the session instead of resuming" do
    out = run_shim_python(<<~PY, fake_chaos: :echo_resumed_pid)
      first, _ = mod.persistent_trigger("sess-4", "REQUEST ONE", None, "claude-opus-4-7", 30)
      second, _ = mod.persistent_trigger("sess-4", "REQUEST TWO", "DELTA ONLY", "claude-haiku-4-5", 30)
      print(json.dumps({"first": first, "second": second}))
    PY

    result = JSON.parse(out)
    second = result["second"]
    assert_equal false, second["session_resumed"]
    assert_equal "model-changed", second["session_roll_reason"]
    assert_equal "rolled", second.dig("telemetry", "session", "outcome")
    assert_equal true, second.dig("telemetry", "session", "mapping_found")
    assert_equal false, second.dig("telemetry", "session", "resume_attempted")
    assert_includes second["full_invocation_text"], "SOUL FIRST"
    assert_not_equal result.dig("first", "chaos_session_id"), second["chaos_session_id"]
  end

  private

  # Runs a Python snippet with trigger_shim.py loaded as `mod`, an isolated
  # identity dir + chaos home, jsonify stubbed to identity (no Flask needed),
  # and CHAOS_BIN pointing at a fake chaos script.
  def run_shim_python(snippet, fake_chaos: nil)
    Dir.mktmpdir do |dir|
      dir = Pathname.new(dir)
      identity = dir / "identity"
      (identity / "memory" / "daily-journals").mkpath
      (identity / "soul.md").write("SOUL FIRST\n")
      chaos_home = dir / "chaos-home"
      chaos_home.mkpath

      chaos_bin = dir / "fake-chaos"
      chaos_bin.write(fake_chaos_script(fake_chaos))
      chaos_bin.chmod(0o755)

      script = Rails.root.join("agent-runtime/trigger_shim.py")
      command = <<~PY
        import importlib.util, json
        spec = importlib.util.spec_from_file_location("trigger_shim", #{script.to_s.inspect})
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        mod.jsonify = lambda payload: payload
        #{snippet}
      PY
      env = {
        "TRIGGER_BEARER_TOKEN" => "tr_test",
        "AGENT_IDENTITY_PATH" => identity.to_s,
        "AGENT_RUNTIME_DOCS_PATH" => Rails.root.join("agent-runtime/docs").to_s,
        "AGENT_REPO_PATH" => dir.to_s,
        "CHAOS_HOME" => chaos_home.to_s,
        "CHAOS_BIN" => chaos_bin.to_s,
        "CLAUDE_CONFIG_DIR" => (dir / "state" / "claude").to_s,
        "CHAOS_AGY_HOME" => (dir / "state" / "antigravity").to_s,
        "AGY_BIN" => (dir / "fake-agy").to_s,
        "SCRIPT_BIN" => "/usr/bin/script",
        "CHAOS_ANTHROPIC_CACHE_TTL" => "1h"
      }
      stdout, stderr, status = Open3.capture3(env, "python3", "-c", command)
      assert status.success?, stderr
      stdout.lines.last.to_s
    end
  end

  # A fake `chaos` that consumes stdin and emits the JSONL events the shim
  # parses. :echo_resumed_pid honours `resume <pid>` (well-behaved chaos);
  # :always_fresh_pid mints a new pid every run (stale-marker scenario).
  def fake_chaos_script(mode)
    honour_resume = (mode != :always_fresh_pid)
    <<~PYTHON
      #!/usr/bin/env python3
      import json, sys, uuid

      args = sys.argv[1:]
      if args and args[0] == "--version":
          print("fake-chaos 0.0.1")
          sys.exit(0)
      sys.stdin.read()

      pid = None
      if #{honour_resume ? 'True' : 'False'} and "resume" in args:
          pid = args[args.index("resume") + 1]
      if pid is None:
          pid = f"pid-{uuid.uuid4()}"

      print(json.dumps({"type": "process.started", "process_id": pid}))
      print(json.dumps({"type": "item.completed", "item": {"id": "1", "type": "agent_message", "text": "fake reply"}}))
      print(json.dumps({
        "type": "turn.completed",
        "telemetry_schema_version": 1,
        "usage": {
          "scope": "invocation",
          "input_tokens": 120,
          "uncached_input_tokens": 80,
          "cache_creation_input_tokens": 10,
          "cache_read_input_tokens": 30,
          "output_tokens": 9,
          "provider_request_count": 1,
        },
        "session_usage": {
          "scope": "process_cumulative",
          "input_tokens": 120,
          "output_tokens": 9,
          "provider_request_count": 1,
        },
      }))
    PYTHON
  end

end
