require "test_helper"

class SoulshouseUsageHelperTest < ActiveSupport::TestCase

  test "shows only the selected Gemini allowance pool" do
    result = run_helper_python(<<~PY)
      payload = {
          "provider": "gemini",
          "model": "gemini-2.5-pro",
          "windows": [
              {
                  "id": "gemini-session",
                  "label": "Gemini 5-hour",
                  "remaining_percent": 100,
                  "resets_at": "2026-08-31T13:00:00Z",
              },
              {
                  "id": "gemini-weekly",
                  "label": "Gemini weekly",
                  "remaining_percent": 95.3,
                  "resets_at": "2026-09-05T19:44:00Z",
              },
              {
                  "id": "claude-session",
                  "label": "Claude/GPT 5-hour",
                  "remaining_percent": 100,
                  "resets_at": "2026-08-31T13:00:00Z",
              },
              {
                  "id": "claude-weekly",
                  "label": "Claude/GPT weekly",
                  "remaining_percent": 100,
                  "resets_at": "2026-09-07T07:26:00Z",
              },
          ],
      }
      print(json.dumps(mod.display_windows(payload)))
    PY

    windows = JSON.parse(result)
    assert_equal [ "5-hour", "Weekly" ], windows.pluck("display_label")
    assert_equal [ "gemini-session", "gemini-weekly" ], windows.pluck("id")
  end

  test "formats an exact-hour reset without sixty minutes" do
    result = run_helper_python(<<~PY)
      from datetime import datetime, timezone
      now = datetime(2026, 8, 31, 8, 0, tzinfo=timezone.utc)
      print(json.dumps(mod.reset_description("2026-08-31T13:00:00Z", now)))
    PY

    assert_equal "resets in 5h", JSON.parse(result)
  end

  test "JSON and human output share the locally computed weekly prediction" do
    result = run_helper_python(<<~PY)
      import contextlib, io
      from datetime import datetime, timezone
      from unittest.mock import patch
      class Clock(datetime):
          @classmethod
          def now(cls, tz=None):
              return cls(2026, 9, 16, 12, 15, tzinfo=timezone.utc)
      weekly = {
          "label": "Weekly", "remaining_percent": 61,
          "resets_at": "2026-09-20T22:32:00Z",
      }
      cases = [
          ({"provider": "anthropic", "windows": [weekly]}, 106),
          ({"provider": "xai", "windows": [weekly]}, 106),
          ({"provider": "openai", "windows": [dict(weekly, id="session", label="Session")]}, 106),
          ({"provider": "gemini", "windows": [
              dict(weekly, label="Claude/GPT weekly", remaining_percent=99),
              dict(weekly, label="Gemini weekly"),
          ]}, 106),
          ({"provider": "openai", "model": "codex-spark", "windows": [
              dict(weekly, label="codex-spark weekly"),
          ]}, 106),
          ({"provider": "anthropic", "windows": []}, None),
          ({"provider": "anthropic", "windows": [dict(weekly, label="Session")]}, None),
          ({"provider": "anthropic", "windows": [dict(weekly, resets_at=None)]}, None),
          ({"provider": "anthropic", "windows": [dict(weekly, resets_at="invalid")]}, None),
          ({"provider": "anthropic", "windows": [dict(weekly, resets_at="2026-09-15T12:15:00Z")]}, None),
          ({"provider": "anthropic", "status": "unknown", "windows": [weekly]}, None),
          ({"provider": "anthropic", "windows": [
              dict(weekly, remaining_percent=100, resets_at="2026-09-23T12:15:00Z"),
          ]}, 0),
          ({"provider": "anthropic", "windows": [
              dict(weekly, resets_at="2026-09-23T12:15:00Z"),
          ]}, None),
      ]
      for payload, expected in cases:
          original = json.dumps(payload, sort_keys=True)
          outputs = []
          def fake_urlopen(request, timeout):
              assert request.full_url == "https://usage.example/api/v1/subscription_usage?refresh=1"
              assert request.get_header("Authorization") == "Bearer synthetic"
              return io.StringIO(json.dumps(payload))
          for args in (["--json", "--refresh"], ["--refresh"]):
              output = io.StringIO()
              with patch.dict(mod.os.environ, {
                  "SOULSHOUSE_APP_URL": "https://usage.example",
                  "SOULSHOUSE_BEARER_TOKEN": "synthetic",
              }, clear=True), patch.object(mod.sys, "argv", ["soulshouse-usage"] + args), \\
                  patch.object(mod, "datetime", Clock), \\
                  patch.object(mod.urllib.request, "urlopen", fake_urlopen), \\
                  contextlib.redirect_stdout(output):
                  assert mod.main() == 0
              outputs.append(output.getvalue())
          snapshot = json.loads(outputs[0])
          if expected is None:
              assert "predicted_weekly_usage_percent" not in snapshot, snapshot
              assert "Predicted usage:" not in outputs[1], outputs[1]
          else:
              assert snapshot.pop("predicted_weekly_usage_percent") == expected, snapshot
              assert f"Predicted usage: {expected}%" in outputs[1], outputs[1]
          assert snapshot == payload, snapshot
          assert json.dumps(payload, sort_keys=True) == original
      print(json.dumps(len(cases)))
    PY

    assert_equal 13, JSON.parse(result)
  end

  private

  def run_helper_python(snippet)
    script = Rails.root.join("agent-runtime/soulshouse-usage")
    command = <<~PY
      import importlib.machinery, importlib.util, json
      loader = importlib.machinery.SourceFileLoader("helixkit_usage", #{script.to_s.inspect})
      spec = importlib.util.spec_from_loader(loader.name, loader)
      mod = importlib.util.module_from_spec(spec)
      loader.exec_module(mod)
      #{snippet}
    PY
    stdout, stderr, status = Open3.capture3("python3", "-c", command)
    assert status.success?, stderr
    stdout
  end

end
