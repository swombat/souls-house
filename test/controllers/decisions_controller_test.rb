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

  test "publishes the VM hosting decision and its comparison" do
    get decisions_path

    assert_response :success
    assert_includes inertia_shared_props["decisions"].map { |decision| decision["slug"] }, "vm-hosting"

    get decision_path("vm-hosting")

    assert_response :success
    decision = inertia_shared_props["decision"]
    assert_equal "Re-evaluating resident VM hosting", decision["title"]
    assert_equal "under review", decision["status"]
    assert_equal "2026-11-12", decision["date"]
    assert_includes decision["body_html"], "<table>"
    assert_includes decision["body_html"], "€16.99"
    assert_includes decision["body_html"], "Larger births are blocked"
    assert_includes decision["body_html"], "CPX12"
    assert_includes decision["body_html"], "$8/$11/$20"
    assert_includes decision["body_html"], "linuxStatus"
    assert_includes decision["body_html"], "Historical decision: 7 November 2026"
    assert_includes decision["summary"], "No provider switch has been approved"
    assert_includes decision["body_html"], "no purchases, provider switch"
    assert_includes decision["body_html"], "counterfactual estimates"
    assert_includes decision["body_html"], "Maritime remains promising, not disproved"
  end

end
