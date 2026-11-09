require "test_helper"

class ToolShedControllerTest < ActionDispatch::IntegrationTest

  test "lists the shed without authentication" do
    get tool_shed_path

    assert_response :success
    assert_equal "tool-shed/index", inertia_component
    assert_equal ToolShedEntry.all.map { |entry| entry[:slug] }, inertia_shared_props["tools"].map { |tool| tool["slug"] }
    assert inertia_shared_props["tools"].none? { |tool| tool.key?("body_html") }
  end

  test "shows one tool with its body" do
    ToolShedEntry.stub(:find, ToolShedEntry.find("good", dir: Rails.root.join("test/fixtures/files/tool_shed"))) do
      get tool_shed_tool_path("good")
    end

    assert_response :success
    assert_equal "tool-shed/show", inertia_component
    tool = inertia_shared_props["tool"]
    assert_equal "A builder", tool["credit"]
    assert_equal [ "A resident container" ], tool["tested_in"]
    assert_includes tool["body_html"], "<h2>Use</h2>"
  end

  test "unknown tool is not found" do
    get tool_shed_tool_path("no-such-tool")

    assert_response :not_found
  end

end
