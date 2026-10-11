require "test_helper"

class SoulshouseXHelperTest < ActiveSupport::TestCase

  test "builds a search request with handles and dates" do
    result = run_helper_python(<<~PY)
      args = mod.build_parser().parse_args([
          "search",
          "What",
          "changed?",
          "--handle",
          "example",
          "--handle",
          "another",
          "--from",
          "2026-09-01",
          "--to",
          "2026-09-02",
      ])
      print(json.dumps(mod.request_payload(args)))
    PY

    assert_equal(
      {
        "operation" => "search",
        "query" => "What changed?",
        "handles" => %w[example another],
        "from_date" => "2026-09-01",
        "to_date" => "2026-09-02"
      },
      JSON.parse(result)
    )
  end

  test "builds a thread request with an optional question" do
    result = run_helper_python(<<~PY)
      args = mod.build_parser().parse_args([
          "thread",
          "https://x.com/example/status/123",
          "What",
          "is",
          "the",
          "evidence?",
      ])
      print(json.dumps(mod.request_payload(args)))
    PY

    assert_equal(
      {
        "operation" => "thread",
        "url" => "https://x.com/example/status/123",
        "question" => "What is the evidence?"
      },
      JSON.parse(result)
    )
  end

  test "formats every request and spend allowance" do
    result = run_helper_python(<<~PY)
      print(mod.allowance_summary({
          "windows": [{
              "id": "agent_hour",
              "requests": {"remaining": 7, "limit": 10},
              "spend": {"remaining_usd": "0.21", "cap_usd": "0.3"},
          }, {
              "id": "account_day",
              "requests": {"remaining": 150, "limit": 200},
              "spend": {"remaining_usd": "4.5", "cap_usd": "6.0"},
          }]
      }))
    PY

    assert_includes result, "resident hour: 7/10 requests left; $0.21/$0.3 left"
    assert_includes result, "account day: 150/200 requests left; $4.5/$6.0 left"
  end

  test "post prints its idempotency key before sending, so an interrupt cannot lose it" do
    result = run_helper_python(<<~PY)
      import io, os, sys
      from unittest import mock
      os.environ["SOULSHOUSE_APP_URL"] = "http://house.test"
      os.environ["SOULSHOUSE_BEARER_TOKEN"] = "token"
      err = io.StringIO()
      seen = {}
      def interrupted(*args, **kwargs):
          seen["stderr_at_send"] = err.getvalue()
          seen["header"] = kwargs["extra_headers"]["Idempotency-Key"]
          raise KeyboardInterrupt
      with mock.patch.object(sys, "argv", ["soulshouse-x", "post", "--key", "key-123", "hello"]), \\
           mock.patch.object(mod, "fetch", interrupted), mock.patch.object(sys, "stderr", err):
          code = mod.main()
      print(json.dumps({"code": code, "before": seen["stderr_at_send"], "header": seen["header"], "after": err.getvalue()}))
    PY

    json = JSON.parse(result)
    assert_equal 130, json["code"]
    assert_equal "key-123", json["header"]
    assert_includes json["before"], "key-123"
    assert_includes json["after"], "--key key-123"
  end

  test "a non-object JSON error body still reports the failure and the key" do
    result = run_helper_python(<<~PY)
      import io, os, sys, urllib.error
      from unittest import mock
      os.environ["SOULSHOUSE_APP_URL"] = "http://house.test"
      os.environ["SOULSHOUSE_BEARER_TOKEN"] = "token"
      err = io.StringIO()
      def null_error(*args, **kwargs):
          raise urllib.error.HTTPError("http://house.test", 502, "Bad Gateway", {}, io.BytesIO(b"null"))
      with mock.patch.object(sys, "argv", ["soulshouse-x", "post", "--key", "key-456", "hello"]), \\
           mock.patch.object(mod, "fetch", null_error), mock.patch.object(sys, "stderr", err):
          code = mod.main()
      print(json.dumps({"code": code, "stderr": err.getvalue()}))
    PY

    json = JSON.parse(result)
    assert_equal 1, json["code"]
    assert_includes json["stderr"], "HTTP 502"
    assert_includes json["stderr"], "key-456"
  end

  private

  def run_helper_python(snippet)
    script = Rails.root.join("agent-runtime/soulshouse-x")
    command = <<~PY
      import importlib.machinery, importlib.util, json
      loader = importlib.machinery.SourceFileLoader("soulshouse_x", #{script.to_s.inspect})
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
