require "test_helper"

class DecisionsControllerTest < ActionDispatch::IntegrationTest

  test "lists decisions without authentication" do
    get decisions_path

    assert_response :success
    assert_equal "decisions/index", inertia_component
    assert_includes inertia_shared_props["decisions"].map { |decision| decision["slug"] }, "free-resident-model"
  end

  test "shows one decision with its body rendered from markdown" do
    get decision_path("free-resident-model")

    assert_response :success
    assert_equal "decisions/show", inertia_component
    decision = inertia_shared_props["decision"]
    assert_equal "Which models a subsidised resident can start on", decision["title"]
    assert_equal "decided", decision["status"]
    assert_includes decision["body_html"], "<h2>How we judge it</h2>"
  end

  test "unknown decision is not found" do
    get decision_path("no-such-decision")

    assert_response :not_found
  end

end
