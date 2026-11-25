require "test_helper"

class ModelRefusalTest < ActiveSupport::TestCase

  test "a refusal counts only with the runtime's failure text showing it" do
    shown = { "error_kind" => "model_unavailable", "runtime_failure" => { "message" => "Model gpt-6.1-sol is not available on your plan" } }
    assert ModelRefusal.evidenced?(shown)
    assert_equal "model_unavailable", ModelRefusal.error_kind(shown)

    [
      { "error_kind" => "model_unavailable" },
      { "error_kind" => "model_unavailable", "runtime_failure" => { "message" => "tool call exceeded its deadline" } },
      { "error_kind" => "model_unavailable", "runtime_failure" => "Invalid model selection" },
      # A rejection without a reason is not a subscription refusal.
      { "error_kind" => "model_unavailable", "runtime_failure" => { "message" => "Invalid model selection: gemini-4-argon" } },
      { "error_kind" => "model_unavailable", "runtime_failure" => { "message" => "gemini-4-argon is not recognized as a known model" } }
    ].each do |body|
      assert_not ModelRefusal.evidenced?(body), body.inspect
      assert_nil ModelRefusal.error_kind(body), body.inspect
    end
  end

  test "other kinds pass through untouched" do
    assert_equal "auth_expired", ModelRefusal.error_kind({ "error_kind" => "auth_expired" })
    assert_nil ModelRefusal.error_kind(nil)
  end

end
