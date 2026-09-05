require "test_helper"

class HistoricalLlmPersistenceTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @model = AiModel.create!(model_id: "archived/model", provider: "openrouter", name: "Archived model")
    @chat = @account.chats.create!(title: "Historical conversation", ai_model: @model)
  end

  test "historical model association wins over legacy default and new selections persist without a registry" do
    @chat.update_column(:model_id_string, "openrouter/auto")
    assert_equal "archived/model", @chat.reload.model_id
    @chat.update!(model_id: "future/model")
    assert_equal "future/model", @chat.reload.model_id
    assert_nil @chat.ai_model
    assert_equal "Archived model", @model.reload.name
  end

  test "signatures tool results tokens and attachment bytes survive reads and forks" do
    payload = { "provider" => "anthropic", "thinking" => { "text" => "Old thinking", "signature" => "signed" } }
    message = @chat.messages.create!(
      role: "assistant", content: "Historical answer", thinking: "Old thinking",
      ai_model: @model, model_id_string: "archived/model", replay_payload: payload,
      input_tokens: 120, output_tokens: 34, cached_tokens: 100, cache_creation_tokens: 5, thinking_tokens: 12,
      tools_used: [ "DeletedTool" ]
    )
    call = message.tool_calls.create!(
      tool_call_id: "provider-call", name: "DeletedTool", arguments: { "input" => "old" },
      replay_payload: { "provider" => "gemini", "thought_signature" => "tool-signed" }
    )
    result = @chat.messages.create!(role: "tool", content: "Historical tool result", parent_tool_call: call)
    message.attachments.attach(io: StringIO.new("archive bytes"), filename: "archive.txt", content_type: "text/plain")

    assert_equal [ message, result ], @chat.reload.messages.to_a
    assert_equal [ result ], message.tool_results.to_a
    assert_equal call, result.parent_tool_call
    assert_equal "signed", message.reload.thinking_signature
    assert_nil message.reasoning_skip_reason
    assert_equal "Old thinking", message.as_json["thinking"]

    forked = @chat.fork_with_title!("Archived copy")
    copy, result_copy = forked.messages.to_a
    %w[content thinking_text thinking_tokens input_tokens output_tokens cached_tokens cache_creation_tokens
       replay_payload tools_used ai_model_id model_id_string].each do |attribute|
      assert_equal message[attribute], copy[attribute], attribute
    end
    assert_equal "archive bytes", copy.attachments.first.download
    assert_equal "tool-signed", copy.tool_calls.first.thought_signature
    assert_equal call.arguments, copy.tool_calls.first.arguments
    assert_equal copy.tool_calls.first, result_copy.parent_tool_call
    assert_equal "Historical tool result", result_copy.content

    call.destroy!
    assert_nil result.reload.parent_tool_call
    assert_equal "Historical tool result", result.content
    forked.destroy!
    assert Message.exists?(message.id)
    assert_equal "archive bytes", message.attachments.first.download
  end

  test "unsigned legacy reasoning remains readable without fabricating signatures" do
    message = @chat.messages.create!(role: "assistant", content: "Old", thinking: "Unsigned")
    assert_equal "legacy_no_signature", message.reasoning_skip_reason
    assert_nil message.thinking_signature
    assert_match "before signed thinking", message.reasoning_skip_reason_label
    message.update!(reasoning_skip_reason: "provider_unsupported")
    assert_equal "provider_unsupported", message.reload.reasoning_skip_reason
  end

end
