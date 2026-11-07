require "test_helper"

class Message::RichUiTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Rich UI model", manual_responses: true, agents: [ @agent ])
    @spec = { "version" => 1, "root" => "text", "elements" => {
      "text" => { "type" => "Text", "props" => { "text" => "Chart data" } }
    } }
  end

  def build_message(**attributes)
    @chat.messages.build(content: "A readable fallback", role: "assistant", agent: @agent, rich_ui: @spec, **attributes)
  end

  test "rich spec persists with its normal message and is present on web JSON" do
    record = build_message
    record.save!
    assert_equal @spec, record.reload.rich_ui
    assert_equal @spec, record.as_json["rich_ui"]
    assert record.revision.positive?
  end

  test "requires resident reply and fallback even for attachments" do
    assert_not build_message(content: "").valid?
    assert_not build_message(agent: nil).valid?
    assert_not build_message(role: "user", user: users(:confirmed_user)).valid?
    assert_not build_message(rich_ui: {}).valid?
  end

  test "designated fallback must be complete content or its exact separated suffix" do
    spec = @spec.merge("fallback" => "Generated summary")
    [ "Generated summary", "Authored caption\n\nGenerated summary" ].each do |content|
      assert build_message(content: content, rich_ui: spec).valid?
    end
    [ "No summary", "Caption\nGenerated summary", "Generated summary\n\nAfterword" ].each do |content|
      record = build_message(content: content, rich_ui: spec)
      assert_not record.valid?
      assert_includes record.errors[:rich_ui].join, "fallback must equal content"
    end
    [ nil, "", " ", {}, "bad\0text", "x" * 3501 ].each do |fallback|
      assert_not build_message(rich_ui: @spec.merge("fallback" => fallback)).valid?
    end
  end

  test "designated fallback persists while transcript retains the full readable content" do
    spec = @spec.merge("fallback" => "Generated summary")
    content = "Authored caption\n\nGenerated summary"
    record = build_message(content: content, rich_ui: spec)
    record.save!
    assert_equal spec, record.reload.as_json["rich_ui"]
    entry = @chat.transcript_for_api.find { |item| item[:id] == record.to_param }
    assert_equal content, entry[:content]
    assert record.update_as_author(content: "Revised prose")
    assert_nil record.reload.rich_ui
  end

  test "changed content clears stale rich UI in the same revision" do
    record = build_message
    record.save!
    revision = record.revision
    assert record.update_as_author(content: "Corrected fallback")
    assert_nil record.reload.rich_ui
    assert_operator record.revision, :>, revision
  end

  test "explicit replacement is validated and preserved while unrelated saves keep data" do
    record = build_message
    record.save!
    record.update!(output_tokens: 5)
    assert_equal @spec, record.reload.rich_ui
    replacement = @spec.deep_dup
    replacement["elements"]["text"]["props"]["text"] = "New data"
    record.update_as_author(content: "New fallback", rich_ui: replacement)
    assert_equal replacement, record.reload.rich_ui
    assert_not record.update(content: "Bad replacement", rich_ui: { "bad" => true })
    assert_equal replacement, record.reload.rich_ui
  end

  test "prose-only duplicates unchanged but distinct rich payloads may share a caption" do
    build_message.save!
    assert_not build_message.valid?
    changed = @spec.deep_dup
    changed["elements"]["text"]["props"]["text"] = "Different"
    assert build_message(rich_ui: changed).valid?
  end

  test "transcript stays compact and discard removes all rich traces" do
    record = build_message
    record.save!
    entry = @chat.transcript_for_api.find { |item| item[:id] == record.to_param }
    assert entry[:rich_ui_summary].present?
    assert_not entry.key?(:rich_ui)
    assert_not_includes entry.to_json, "Chart data"
    record.discard!
    assert_not @chat.transcript_for_api.any? { |item| item[:id] == record.to_param }
  end

end
