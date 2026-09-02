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
