require "test_helper"

# Mira's P2 on 169cdeae: `status` is the recovery door after --no-wait, so
# every terminal state must say what it is, and only a post that is on
# LinkedIn exits 0.
class SoulshouseLinkedinHelperTest < ActiveSupport::TestCase

  test "a failed post prints its reason and exits 1" do
    out, err, code = report({ "id" => "p1", "status" => "failed", "failure_reason" => "access_removed",
                              "error" => "Nothing was sent: access was switched off" })

    assert_equal 1, code
    assert_equal "", out
    assert_match(/p1 was not sent \(access_removed\): Nothing was sent/, err)
  end

  test "a post resolved as not posted says so and exits 1" do
    _out, err, code = report({ "id" => "p2", "status" => "resolved_not_posted" })

    assert_equal 1, code
    assert_match(/resolved as not posted/, err)
  end

  test "a posted post prints its URL and exits 0" do
    out, err, code = report({ "id" => "p3", "status" => "posted", "url" => "https://www.linkedin.com/feed/update/urn:li:share:1/" })

    assert_equal 0, code
    assert_equal "https://www.linkedin.com/feed/update/urn:li:share:1/", out.strip
    assert_equal "", err
  end

  test "a post resolved as posted exits 0" do
    out, _err, code = report({ "id" => "p4", "status" => "resolved_posted", "url" => "https://www.linkedin.com/feed/update/urn:li:share:2/" })

    assert_equal 0, code
    assert_match(/urn:li:share:2/, out)
  end

  test "an unknown outcome exits 1 with the resolve instructions" do
    _out, err, code = report({ "id" => "p5", "status" => "outcome_unknown" })

    assert_equal 1, code
    assert_match(/resolve p5 --posted/, err)
  end

  private

  def report(result, status_code: 200)
    script = Rails.root.join("agent-runtime/soulshouse-linkedin")
    command = <<~PY
      import importlib.machinery, importlib.util, json, sys, types
      loader = importlib.machinery.SourceFileLoader("soulshouse_linkedin", #{script.to_s.inspect})
      spec = importlib.util.spec_from_loader(loader.name, loader)
      mod = importlib.util.module_from_spec(spec)
      loader.exec_module(mod)
      code = mod.report(json.loads(sys.argv[1]), #{status_code}, types.SimpleNamespace(json=False))
      sys.exit(code)
    PY
    stdout, stderr, status = Open3.capture3("python3", "-c", command, result.to_json)
    [ stdout, stderr, status.exitstatus ]
  end

end
