require "test_helper"
require "action_cable/test_helper"

class AgentRuntimeInteractionTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  test "records trigger result stdout and stderr" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Runtime log")

    result = AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_id: chat.to_param,
      requested_by: "test",
      session_id: "session-1",
      endpoint_url: "https://agent.example.com",
      request_text: "Please respond"
    ) do
      {
        status: 200,
        body: {
          "status" => "ok",
          "returncode" => 0,
          "stdout" => "hello from runtime",
          "stderr" => "diagnostic noise"
        }
      }
    end

    interaction = AgentRuntimeInteraction.last
    assert_equal 200, result[:status]
    assert_equal agent, interaction.agent
    assert_equal chat, interaction.chat
    assert_equal "ok", interaction.runtime_status
    assert_equal 0, interaction.runtime_returncode
    assert_equal "hello from runtime", interaction.stdout
    assert_equal "diagnostic noise", interaction.stderr
    assert_not_nil interaction.duration_ms
  end

  test "records the auth mode used for the trigger and marks subscription estimates as non-billable" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openai/gpt-5", title: "Subscription cost")

    AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_id: chat.to_param,
      requested_by: "test",
      session_id: "subscription-session",
      endpoint_url: "https://agent.example.com",
      request_text: "Please respond",
      provider_auth_mode: "oauth_account"
    ) do
      { status: 200, body: { "status" => "ok" } }
    end

    interaction = AgentRuntimeInteraction.last
    assert_equal "oauth_account", interaction.provider_auth_mode
    assert_predicate interaction, :subscription_based?
    assert_equal false, interaction.estimated_cost[:applies_to_billing]
    assert_equal true, interaction.as_cost_json[:subscription_based]
  end

  test "cost json exposes only trigger-local detailed usage" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Cost context")
    interaction = AgentRuntimeInteraction.create!(
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      requested_by: "test",
      started_at: Time.current,
      telemetry_schema_version: 1,
      chaos_telemetry_status: "detailed",
      usage_scope: "trigger",
      usage_complete: true,
      provider: "anthropic",
      model: "claude-fable-5",
      session_outcome: "resumed",
      prompt_mode: "delta",
      cache_read_input_tokens: 400,
      cache_creation_input_tokens: 0,
      uncached_input_tokens: 0,
      output_tokens: 20
    )

    json = interaction.as_cost_json

    assert_equal "complete", json[:telemetry_state]
    assert_equal "Cost context", json[:chat_title]
    assert_equal "Conversation · Resumed · delta prompt", json[:summary]
    assert_equal 400, json.dig(:tokens, :cache_read_input_tokens)
    assert_equal "estimated", json.dig(:estimated_cost, :status)
    assert_equal "0.0014", json.dig(:estimated_cost, :amount_usd)
  end

  test "broadcasts agent runtime interactions refresh when recorded" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Runtime log")

    assert_broadcasts("Agent:#{agent.obfuscated_id}", 3) do
      assert_broadcasts("Chat:#{chat.obfuscated_id}", 4) do
        AgentRuntimeInteraction.record_trigger!(
          agent: agent,
          chat: chat,
          trigger_kind: "conversation",
          conversation_id: chat.to_param,
          requested_by: "test",
          session_id: "session-1",
          endpoint_url: "https://agent.example.com",
          request_text: "Please respond"
        ) do
          { status: 200, body: { "status" => "ok" } }
        end
      end
    end
  end

  test "refreshes the one chat response obviously linked to a completed wake" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Wake response")
    started_at = 1.minute.ago
    chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "One wake response",
      created_at: started_at + 10.seconds
    )

    assert_broadcasts("Chat:#{chat.obfuscated_id}", 2) do
      AgentRuntimeInteraction.create!(
        agent: agent,
        trigger_kind: "wake",
        started_at: started_at,
        finished_at: started_at + 20.seconds
      )
    end
  end

  test "chat timeline activity remains visible after a reply and excludes diagnostics" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Runtime log")

    interaction = AgentRuntimeInteraction.create!(
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_obfuscated_id: chat.to_param,
      requested_by: "test",
      session_id: "session-1",
      endpoint_url: "https://agent.example.com",
      request_text: "Please respond",
      started_at: 1.minute.ago,
      finished_at: Time.current,
      stdout: "I chose not to post."
    )

    assert interaction.visible_in_chat_timeline?
    assert_equal "completed_without_reply", interaction.as_chat_activity_json[:status]

    chat.messages.create!(role: "assistant", agent: agent, content: "Actually posting.")

    assert interaction.visible_in_chat_timeline?
    assert_not interaction.as_chat_activity_json.key?(:stdout)
    assert_not interaction.as_chat_activity_json.key?(:stderr)
  end

  test "record_result! maps chaos session and usage fields from the response body" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Runtime log")

    AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_id: chat.to_param,
      requested_by: "test",
      session_id: "session-1",
      endpoint_url: "https://agent.example.com",
      request_text: "Please respond",
      last_included_message_id: 42
    ) do
      {
        status: 200,
        body: {
          "status" => "ok",
          "chaos_session_id" => "chaos-abc",
          "session_resumed" => true,
          "fresh_fallback" => false,
          "usage" => { "input_tokens" => 100, "cached_input_tokens" => 40, "output_tokens" => 20 }
        }
      }
    end

    interaction = AgentRuntimeInteraction.last
    assert_equal 42, interaction.last_included_message_id
    assert_equal "chaos-abc", interaction.chaos_session_id
    assert interaction.session_resumed
    assert_not interaction.fresh_fallback
    assert_equal 100, interaction.input_tokens
    assert_equal 40, interaction.cached_input_tokens
    assert_equal 20, interaction.output_tokens
  end

  test "record_result! leaves usage and session fields nil when absent from the response body" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Runtime log")

    AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_id: chat.to_param,
      requested_by: "test",
      session_id: "session-1",
      endpoint_url: "https://agent.example.com",
      request_text: "Please respond"
    ) do
      { status: 200, body: { "status" => "ok" } }
    end

    interaction = AgentRuntimeInteraction.last
    assert_nil interaction.last_included_message_id
    assert_nil interaction.chaos_session_id
    assert_nil interaction.session_resumed
    assert_nil interaction.fresh_fallback
    assert_nil interaction.input_tokens
    assert_nil interaction.cached_input_tokens
    assert_nil interaction.output_tokens
  end

  test "record_result! persists versioned invocation telemetry without conflating unknown and zero" do
    agent = agents(:research_assistant)
    chat = agent.account.chats.create!(model_id: "openrouter/auto", title: "Runtime telemetry")

    AgentRuntimeInteraction.record_trigger!(
      agent: agent,
      chat: chat,
      trigger_kind: "conversation",
      conversation_id: chat.to_param,
      requested_by: "test",
      session_id: "session-observed",
      endpoint_url: "https://agent.example.com",
      request_text: "Please respond"
    ) do
      {
        status: 200,
        body: {
          "status" => "ok",
          "telemetry" => {
            "schema_version" => 1,
            "chaos_telemetry_status" => "detailed",
            "runtime" => {
              "chaos_version" => "chaos 1.2.3 (abc1234)",
              "provider" => "anthropic",
              "model" => "claude-fable-5",
              "cache_ttl" => "1h"
            },
            "session" => {
              "persistent_requested" => true,
              "mapping_found" => true,
              "resume_attempted" => true,
              "outcome" => "resumed",
              "roll_reason" => nil,
              "changed_identity_files" => [],
              "prior_chaos_process_id" => "chaos-1",
              "chaos_process_id" => "chaos-1",
              "trigger_sequence" => 3,
              "session_age_seconds" => 120
            },
            "prompt" => {
              "mode" => "delta",
              "full_prompt_bytes" => 90_000,
              "delta_prompt_bytes" => 3_000,
              "selected_prompt_bytes" => 3_000,
              "components" => {}
            },
            "usage" => {
              "scope" => "invocation",
              "input_tokens" => 1_500,
              "uncached_input_tokens" => 0,
              "cache_creation_input_tokens" => 100,
              "cache_read_input_tokens" => 1_400,
              "output_tokens" => 50,
              "reasoning_output_tokens" => nil,
              "provider_request_count" => 2
            }
          }
        }
      }
    end

    interaction = AgentRuntimeInteraction.last
    assert_equal 1, interaction.telemetry_schema_version
    assert_equal "detailed", interaction.chaos_telemetry_status
    assert_equal "chaos 1.2.3 (abc1234)", interaction.chaos_version
    assert_equal "anthropic", interaction.provider
    assert_equal "claude-fable-5", interaction.model
    assert_equal "1h", interaction.cache_ttl
    assert interaction.persistent_session_requested
    assert interaction.session_mapping_found
    assert interaction.resume_attempted
    assert_equal "resumed", interaction.session_outcome
    assert_equal [], interaction.changed_identity_files
    assert_equal "chaos-1", interaction.chaos_session_id
    assert_equal "delta", interaction.prompt_mode
    assert_equal 3_000, interaction.selected_prompt_bytes
    assert_equal "invocation", interaction.usage_scope
    assert_equal 0, interaction.uncached_input_tokens
    assert_equal 100, interaction.cache_creation_input_tokens
    assert_equal 1_400, interaction.cache_read_input_tokens
    assert_equal 1_400, interaction.cached_input_tokens
    assert_nil interaction.reasoning_output_tokens
    assert_equal 2, interaction.provider_request_count
    assert interaction.usage_complete
  end

  test "old runtime response does not fabricate detailed telemetry" do
    interaction = AgentRuntimeInteraction.create!(
      agent: agents(:research_assistant),
      trigger_kind: "wake",
      session_id: "old-runtime",
      started_at: Time.current
    )

    interaction.record_result!(
      status: 200,
      body: {
        "status" => "ok",
        "usage" => {
          "input_tokens" => 100,
          "cached_input_tokens" => 40,
          "output_tokens" => 20
        }
      }
    )

    assert_equal 100, interaction.input_tokens
    assert_equal 40, interaction.cached_input_tokens
    assert_nil interaction.telemetry_schema_version
    assert_nil interaction.cache_creation_input_tokens
    assert_nil interaction.cache_read_input_tokens
    assert_nil interaction.provider_request_count
    assert_nil interaction.usage_complete
  end

  test "record_result! persists trigger-local usage aggregated across fallback invocations" do
    interaction = AgentRuntimeInteraction.create!(
      agent: agents(:research_assistant),
      trigger_kind: "conversation",
      session_id: "fallback-trigger",
      started_at: Time.current
    )

    interaction.record_result!(
      status: 200,
      body: {
        "status" => "ok",
        "telemetry" => {
          "schema_version" => 1,
          "chaos_telemetry_status" => "detailed",
          "usage" => {
            "scope" => "trigger",
            "complete" => true,
            "input_tokens" => 2_000,
            "uncached_input_tokens" => 100,
            "cache_creation_input_tokens" => 300,
            "cache_read_input_tokens" => 1_600,
            "output_tokens" => 80,
            "provider_request_count" => 4
          }
        }
      }
    )

    assert_equal "trigger", interaction.usage_scope
    assert interaction.usage_complete
    assert_equal 2_000, interaction.input_tokens
    assert_equal 300, interaction.cache_creation_input_tokens
    assert_equal 1_600, interaction.cache_read_input_tokens
    assert_equal 4, interaction.provider_request_count
  end

  test "telemetry envelope without detailed usage does not upgrade coarse fallback usage" do
    interaction = AgentRuntimeInteraction.create!(
      agent: agents(:research_assistant),
      trigger_kind: "wake",
      session_id: "mixed-runtime",
      started_at: Time.current
    )

    interaction.record_result!(
      status: 200,
      body: {
        "status" => "ok",
        "telemetry" => {
          "schema_version" => 1,
          "runtime" => { "provider" => "anthropic" },
          "session" => { "outcome" => "fresh" }
        },
        "usage" => {
          "input_tokens" => 100,
          "cached_input_tokens" => 40,
          "output_tokens" => 20
        }
      }
    )

    assert_equal 1, interaction.telemetry_schema_version
    assert_equal "anthropic", interaction.provider
    assert_equal 40, interaction.cached_input_tokens
    assert_nil interaction.cache_read_input_tokens
    assert_nil interaction.cache_creation_input_tokens
    assert_nil interaction.usage_scope
    assert_nil interaction.usage_complete
  end

  test "unversioned additive usage remains coarse because invocation scope is unknown" do
    interaction = AgentRuntimeInteraction.create!(
      agent: agents(:research_assistant),
      trigger_kind: "memory_aggregation_daily",
      session_id: "legacy-json",
      started_at: Time.current
    )

    interaction.record_result!(
      status: 200,
      body: {
        "status" => "ok",
        "usage" => {
          "input_tokens" => 100,
          "cache_creation_input_tokens" => 20,
          "cached_input_tokens" => 70,
          "output_tokens" => 5,
          "reasoning_output_tokens" => 1,
          "provider_request_count" => 2
        }
      }
    )

    assert_nil interaction.uncached_input_tokens
    assert_nil interaction.cache_creation_input_tokens
    assert_nil interaction.cache_read_input_tokens
    assert_equal 70, interaction.cached_input_tokens
    assert_nil interaction.reasoning_output_tokens
    assert_nil interaction.provider_request_count
    assert_nil interaction.usage_complete
  end

  test "unsupported Chaos telemetry remains explicitly diagnosable" do
    interaction = AgentRuntimeInteraction.create!(
      agent: agents(:research_assistant),
      trigger_kind: "wake",
      session_id: "unsupported-runtime",
      started_at: Time.current
    )

    interaction.record_result!(
      status: 200,
      body: {
        "status" => "ok",
        "telemetry" => {
          "schema_version" => 1,
          "chaos_telemetry_status" => "unsupported",
          "unsupported_chaos_telemetry_schema_version" => 99,
          "usage" => nil
        }
      }
    )

    assert_equal "unsupported", interaction.chaos_telemetry_status
    assert_equal 99, interaction.unsupported_chaos_telemetry_schema_version
    assert_nil interaction.input_tokens
    assert_nil interaction.cache_creation_input_tokens
    assert_nil interaction.usage_complete
  end

  test "versioned usage derives uncached input only when all categories are known" do
    interaction = AgentRuntimeInteraction.create!(
      agent: agents(:research_assistant),
      trigger_kind: "wake",
      session_id: "derived-input",
      started_at: Time.current
    )

    interaction.record_result!(
      status: 200,
      body: {
        "status" => "ok",
        "telemetry" => {
          "schema_version" => 1,
          "usage" => {
            "scope" => "invocation",
            "input_tokens" => 100,
            "cache_creation_input_tokens" => 20,
            "cache_read_input_tokens" => 70,
            "output_tokens" => 5
          }
        }
      }
    )

    assert_equal 10, interaction.uncached_input_tokens

    interaction.record_result!(
      status: 200,
      body: {
        "status" => "ok",
        "telemetry" => {
          "schema_version" => 1,
          "usage" => {
            "scope" => "invocation",
            "input_tokens" => 100,
            "cache_creation_input_tokens" => nil,
            "cache_read_input_tokens" => 70,
            "output_tokens" => 5
          }
        }
      }
    )

    assert_nil interaction.uncached_input_tokens
  end

  test "token and lifecycle helpers preserve unknown values" do
    interaction = AgentRuntimeInteraction.new(
      session_outcome: "resumed",
      prompt_mode: "delta",
      input_tokens: 200,
      cache_creation_input_tokens: 20,
      cache_read_input_tokens: 150,
      output_tokens: 10,
      provider_request_count: 3
    )

    assert interaction.resumed_session?
    assert_not interaction.fresh_session?
    assert_not interaction.cold_start?
    assert_in_delta 0.75, interaction.cache_read_ratio
    assert_in_delta 0.10, interaction.cache_creation_ratio
    assert_equal 3, interaction.provider_requests_per_trigger
    assert_equal(
      {
        input: 200,
        uncached_input: nil,
        cache_creation_input: 20,
        cache_read_input: 150,
        output: 10,
        reasoning_output: nil
      },
      interaction.token_breakdown
    )

    interaction.assign_attributes(session_outcome: "rolled", prompt_mode: "full", input_tokens: nil)
    assert interaction.cold_start?
    assert_nil interaction.cache_read_ratio
  end

  test "observability migration uses query-safe numeric and structured column types" do
    columns = AgentRuntimeInteraction.columns_hash

    assert_equal :integer, columns.fetch("telemetry_schema_version").type
    assert_equal :string, columns.fetch("chaos_telemetry_status").type
    assert_equal :integer, columns.fetch("unsupported_chaos_telemetry_schema_version").type
    assert_equal "bigint", columns.fetch("full_prompt_bytes").sql_type
    assert_equal :jsonb, columns.fetch("changed_identity_files").type
    assert_equal :jsonb, columns.fetch("prompt_component_bytes").type
    assert_equal "bigint", columns.fetch("cache_creation_input_tokens").sql_type
    assert_equal :integer, columns.fetch("provider_request_count").type
    assert_equal :boolean, columns.fetch("usage_complete").type
  end

end
