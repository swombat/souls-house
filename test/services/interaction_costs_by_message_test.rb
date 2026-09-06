require "test_helper"

class InteractionCostsByMessageTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Linked costs")
    @started_at = Time.utc(2026, 7, 22, 12)
  end

  test "links a conversation interaction that produced exactly one assistant message" do
    message = create_message!(at: @started_at + 10.seconds)
    create_interaction!(finished_at: @started_at + 20.seconds)

    costs = InteractionCostsByMessage.new(chat: @chat, messages: [ message ]).call

    assert_equal "0.00225", costs.dig(message.id, :amount_usd)
    assert_equal true, costs.dig(message.id, :applies_to_billing)
  end

  test "explicit multi-reply runs charge only the first reply even across pages" do
    first = create_message!(at: @started_at + 10.seconds)
    second = create_message!(at: @started_at + 15.seconds)
    unlinked = create_message!(at: @started_at + 17.seconds)
    run = create_interaction!(finished_at: @started_at + 20.seconds)
    first.update!(runtime_interaction: run)
    second.update!(runtime_interaction: run)
    assert_equal({ first.id => run }, InteractionCostsByMessage.new(chat: @chat, messages: [ first, second, unlinked ]).linked_interactions)
    assert_empty InteractionCostsByMessage.new(chat: @chat, messages: [ second, unlinked ]).call
  end

  test "marks a linked subscription interaction estimate as non-billable" do
    message = create_message!(at: @started_at + 10.seconds)
    create_interaction!(
      finished_at: @started_at + 20.seconds,
      provider_auth_mode: "oauth_account"
    )

    costs = InteractionCostsByMessage.new(chat: @chat, messages: [ message ]).call

    assert_equal "0.00225", costs.dig(message.id, :amount_usd)
    assert_equal false, costs.dig(message.id, :applies_to_billing)
  end

  test "does not link an interaction that produced several messages" do
    first = create_message!(at: @started_at + 10.seconds)
    create_message!(at: @started_at + 15.seconds)
    create_interaction!(finished_at: @started_at + 20.seconds)

    costs = InteractionCostsByMessage.new(chat: @chat, messages: [ first ]).call

    assert_empty costs
  end

  test "links a wake that produced exactly one assistant message across the account" do
    message = create_message!(at: @started_at + 10.seconds)
    create_interaction!(chat: nil, trigger_kind: "wake", finished_at: @started_at + 20.seconds)

    costs = InteractionCostsByMessage.new(chat: @chat, messages: [ message ]).call

    assert_equal "0.00225", costs.dig(message.id, :amount_usd)
  end

  test "does not link a wake that posted to several conversations" do
    message = create_message!(at: @started_at + 10.seconds)
    other_chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Another wake destination")
    create_message!(chat: other_chat, at: @started_at + 15.seconds)
    create_interaction!(chat: nil, trigger_kind: "wake", finished_at: @started_at + 20.seconds)

    costs = InteractionCostsByMessage.new(chat: @chat, messages: [ message ]).call

    assert_empty costs
  end

  test "does not link a message claimed by overlapping interactions" do
    message = create_message!(at: @started_at + 10.seconds)
    create_interaction!(finished_at: @started_at + 20.seconds)
    create_interaction!(started_at: @started_at + 5.seconds, finished_at: @started_at + 15.seconds)

    costs = InteractionCostsByMessage.new(chat: @chat, messages: [ message ]).call

    assert_empty costs
  end

  test "ignores interactions that do not post to HelixKit conversations" do
    message = create_message!(at: @started_at + 10.seconds)
    create_interaction!(chat: nil, trigger_kind: "telegram", finished_at: @started_at + 20.seconds)

    costs = InteractionCostsByMessage.new(chat: @chat, messages: [ message ]).call

    assert_empty costs
  end

  private

  def create_message!(at:, chat: @chat)
    chat.messages.create!(
      role: "assistant",
      agent: @agent,
      content: "A linked response at #{at.to_f} in #{chat.id}",
      created_at: at
    )
  end

  def create_interaction!(**attributes)
    AgentRuntimeInteraction.create!(
      {
        agent: @agent,
        chat: @chat,
        trigger_kind: "conversation",
        started_at: @started_at,
        telemetry_schema_version: 1,
        usage_scope: "trigger",
        usage_complete: true,
        provider: "anthropic",
        model: "claude-sonnet-5",
        uncached_input_tokens: 1_000,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 0,
        output_tokens: 25
      }.merge(attributes)
    )
  end

end
