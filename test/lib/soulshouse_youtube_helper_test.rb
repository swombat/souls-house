require "test_helper"

class SoulshouseYoutubeHelperTest < ActiveSupport::TestCase

  test "builds an ask request from a multi-word question" do
    result = run_helper_python(<<~PY)
      args = mod.build_parser().parse_args([
          "ask",
          "https://youtu.be/56Vy6cGfXXY",
          "What",
          "is",
          "the",
          "conclusion?",
      ])
      print(json.dumps(mod.request_payload(args)))
    PY

    payload = JSON.parse(result)
    assert_equal "ask", payload["operation"]
    assert_equal "What is the conclusion?", payload["question"]
  end

  test "builds a transcript request without a question" do
    result = run_helper_python(<<~PY)
      args = mod.build_parser().parse_args([
          "transcript",
          "https://youtu.be/56Vy6cGfXXY",
          "--output",
          "~/work/transcript.md",
      ])
      print(json.dumps(mod.request_payload(args)))
    PY

    assert_equal(
      {
        "url" => "https://youtu.be/56Vy6cGfXXY",
        "operation" => "transcript"
      },
      JSON.parse(result)
    )
  end

  private

  def run_helper_python(snippet)
    script = Rails.root.join("agent-runtime/soulshouse-youtube")
    command = <<~PY
      import importlib.machinery, importlib.util, json
      loader = importlib.machinery.SourceFileLoader("soulshouse_youtube", #{script.to_s.inspect})
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
