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
