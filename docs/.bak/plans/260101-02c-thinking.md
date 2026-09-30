# Implementation Plan: Extended Thinking for AI Agents (Final)

**Date**: 2026-01-01
**Spec**: 260101-02c-thinking
**Requirements**: `/docs/requirements/260101-02-thinking.md`
**Previous iteration**: `/docs/plans/260101-02b-thinking.md`
**DHH approval**: `/docs/plans/260101-02b-thinking-dhh-feedback.md`

---

## Executive Summary

This is the definitive implementation guide for extended thinking (reasoning) support for AI agents. The design has been approved by DHH as "Rails-worthy code" and follows the single source of truth principle throughout.

**Key architectural decisions:**
1. `Chat::MODELS` extended with thinking capability metadata - one source of truth
2. `SelectsLlmProvider` routes based on model metadata, not hardcoded lists
3. `StreamBuffer` extracted as a focused class for debounced streaming
4. Transient errors broadcast to UI rather than creating permanent error messages

---

## Architecture Overview

```
Chat::MODELS (single source of truth)
       |
       +-- Chat.supports_thinking?(model_id)
       +-- Chat.requires_direct_api_for_thinking?(model_id)
       +-- Chat.provider_model_id(model_id)
       +-- Agent.uses_thinking? (derived)
       +-- SelectsLlmProvider.llm_provider_for (derived)
       +-- Frontend grouped_models (derived via controller)

StreamBuffer (extracted class)
       |
       +-- @content_buffer (in StreamsAiResponse)
       +-- @thinking_buffer (in StreamsAiResponse)
```

---

## Implementation Steps

### Phase 1: Database Migrations

#### Step 1.1: Add thinking column to messages
- [ ] Create migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_thinking_to_messages.rb
class AddThinkingToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :thinking, :text
  end
end
```

#### Step 1.2: Add thinking settings to agents
- [ ] Create migration

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_thinking_settings_to_agents.rb
class AddThinkingSettingsToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :thinking_enabled, :boolean, default: false, null: false
    add_column :agents, :thinking_budget, :integer, default: 10000
  end
end
```

Run migrations:
```bash
rails db:migrate
```

---

### Phase 2: Model Capabilities - Single Source of Truth

#### Step 2.1: Extend Chat::MODELS with thinking metadata
- [ ] Update `app/models/chat.rb`

Replace the existing `MODELS` constant with this version that includes thinking capability metadata:

```ruby
# In app/models/chat.rb - replace the existing MODELS constant

MODELS = [
  # Top Models - Flagship from each major provider
  {
    model_id: "openai/gpt-5.2",
    label: "GPT-5.2",
    group: "Top Models",
    thinking: { supported: true }
  },
  {
    model_id: "anthropic/claude-opus-4.5",
    label: "Claude Opus 4.5",
    group: "Top Models",
    thinking: { supported: true, requires_direct_api: true, provider_model_id: "claude-opus-4-5-20251101" }
  },
  {
    model_id: "google/gemini-3-pro-preview",
    label: "Gemini 3 Pro",
    group: "Top Models",
    thinking: { supported: true }
  },
  { model_id: "x-ai/grok-4.1-fast", label: "Grok 4.1 Fast", group: "Top Models" },
  { model_id: "deepseek/deepseek-v3.2", label: "DeepSeek V3.2", group: "Top Models" },

  # OpenAI
  { model_id: "openai/gpt-5.1", label: "GPT-5.1", group: "OpenAI", thinking: { supported: true } },
  { model_id: "openai/gpt-5", label: "GPT-5", group: "OpenAI", thinking: { supported: true } },
  { model_id: "openai/gpt-5-mini", label: "GPT-5 Mini", group: "OpenAI" },
  { model_id: "openai/gpt-5-nano", label: "GPT-5 Nano", group: "OpenAI" },
  { model_id: "openai/o3", label: "O3", group: "OpenAI" },
  { model_id: "openai/o3-mini", label: "O3 Mini", group: "OpenAI" },
  { model_id: "openai/o4-mini-high", label: "O4 Mini High", group: "OpenAI" },
  { model_id: "openai/o4-mini", label: "O4 Mini", group: "OpenAI" },
  { model_id: "openai/o1", label: "O1", group: "OpenAI" },
  { model_id: "openai/gpt-4.1", label: "GPT-4.1", group: "OpenAI" },
  { model_id: "openai/gpt-4.1-mini", label: "GPT-4.1 Mini", group: "OpenAI" },
  { model_id: "openai/gpt-4o", label: "GPT-4o", group: "OpenAI" },
  { model_id: "openai/gpt-4o-mini", label: "GPT-4o Mini", group: "OpenAI" },

  # Anthropic
  {
    model_id: "anthropic/claude-sonnet-4.5",
    label: "Claude Sonnet 4.5",
    group: "Anthropic",
    thinking: { supported: true, requires_direct_api: true, provider_model_id: "claude-sonnet-4-5-20251201" }
  },
  { model_id: "anthropic/claude-haiku-4.5", label: "Claude Haiku 4.5", group: "Anthropic" },
  {
    model_id: "anthropic/claude-opus-4",
    label: "Claude Opus 4",
    group: "Anthropic",
    thinking: { supported: true, requires_direct_api: true, provider_model_id: "claude-opus-4-20250514" }
  },
  {
    model_id: "anthropic/claude-sonnet-4",
    label: "Claude Sonnet 4",
    group: "Anthropic",
    thinking: { supported: true, requires_direct_api: true, provider_model_id: "claude-sonnet-4-20250514" }
  },
  {
    model_id: "anthropic/claude-3.7-sonnet",
    label: "Claude 3.7 Sonnet",
    group: "Anthropic",
    thinking: { supported: true }
  },
  { model_id: "anthropic/claude-3.5-sonnet", label: "Claude 3.5 Sonnet", group: "Anthropic" },
  { model_id: "anthropic/claude-3-opus", label: "Claude 3 Opus", group: "Anthropic" },

  # Google
  { model_id: "google/gemini-3-flash-preview", label: "Gemini 3 Flash", group: "Google" },
  { model_id: "google/gemini-2.5-pro", label: "Gemini 2.5 Pro", group: "Google" },
  { model_id: "google/gemini-2.5-flash", label: "Gemini 2.5 Flash", group: "Google" },

  # xAI
  { model_id: "x-ai/grok-4-fast", label: "Grok 4 Fast", group: "xAI" },
  { model_id: "x-ai/grok-4", label: "Grok 4", group: "xAI" },
  { model_id: "x-ai/grok-3", label: "Grok 3", group: "xAI" },

  # DeepSeek
  { model_id: "deepseek/deepseek-r1", label: "DeepSeek R1", group: "DeepSeek" },
  { model_id: "deepseek/deepseek-v3", label: "DeepSeek V3", group: "DeepSeek" }
].freeze
```

#### Step 2.2: Add Chat class methods for model lookups
- [ ] Add class methods to `app/models/chat.rb` (after the MODELS constant)

```ruby
# In app/models/chat.rb - add these class methods after MODELS

def self.model_config(model_id)
  MODELS.find { |m| m[:model_id] == model_id }
end

def self.supports_thinking?(model_id)
  model_config(model_id)&.dig(:thinking, :supported) == true
end

def self.requires_direct_api_for_thinking?(model_id)
  model_config(model_id)&.dig(:thinking, :requires_direct_api) == true
end

def self.provider_model_id(model_id)
  model_config(model_id)&.dig(:thinking, :provider_model_id) || model_id.to_s.sub(%r{^.+/}, "")
end
```

#### Step 2.3: Update Agent model
- [ ] Update `app/models/agent.rb`

Add validation, json_attributes, and the `uses_thinking?` method:

```ruby
# In app/models/agent.rb

# Add to existing validations
validates :thinking_budget,
          numericality: { greater_than_or_equal_to: 1000, less_than_or_equal_to: 50000 },
          allow_nil: true

# Update json_attributes to include thinking settings
json_attributes :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
                :model_id, :model_label, :enabled_tools, :active?, :colour, :icon,
                :memories_count, :thinking_enabled, :thinking_budget

# Add this method (public, before the private section)
def uses_thinking?
  thinking_enabled? && Chat.supports_thinking?(model_id)
end
```

#### Step 2.4: Update Message model
- [ ] Update `app/models/message.rb`

Add thinking to json_attributes and add streaming/preview methods:

```ruby
# In app/models/message.rb

# Update json_attributes to include thinking
json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                :completed, :created_at_formatted, :created_at_hour, :streaming,
                :files_json, :content_html, :tools_used, :tool_status,
                :author_name, :author_type, :author_colour, :input_tokens, :output_tokens

# Add these methods (public, before the private section)
def thinking_preview
  return nil if thinking.blank?
  thinking.truncate(80, separator: " ")
end

def stream_thinking(chunk)
  chunk = chunk.to_s
  return if chunk.empty?

  update_columns(thinking: (thinking.to_s + chunk))

  broadcast_marker(
    "Message:#{to_param}",
    {
      action: "thinking_update",
      chunk: chunk,
      id: to_param
    }
  )
end
```

---

### Phase 3: Provider Routing

#### Step 3.1: Refactor SelectsLlmProvider
- [ ] Update `app/jobs/concerns/selects_llm_provider.rb`

Replace the entire file with this data-driven implementation:

```ruby
# frozen_string_literal: true

# Determines the correct LLM provider based on model ID and configuration.
#
# Routes to appropriate providers:
# - Anthropic direct: for Claude 4+ models with thinking enabled
# - Gemini direct: for Google models (due to thought_signature requirements)
# - OpenRouter: fallback for all other models
module SelectsLlmProvider
  extend ActiveSupport::Concern

  private

  # Returns the provider and normalized model ID for a given model
  #
  # @param model_id [String] The model ID (e.g., "anthropic/claude-opus-4.5")
  # @param thinking_enabled [Boolean] Whether thinking is enabled for this request
  # @return [Hash] { provider: Symbol, model_id: String, thinking: Boolean }
  def llm_provider_for(model_id, thinking_enabled: false)
    if thinking_enabled && Chat.requires_direct_api_for_thinking?(model_id) && anthropic_api_available?
      {
        provider: :anthropic,
        model_id: Chat.provider_model_id(model_id),
        thinking: true
      }
    elsif gemini_model?(model_id) && gemini_direct_access_enabled?
      {
        provider: :gemini,
        model_id: normalize_gemini_model_id(model_id)
      }
    else
      {
        provider: :openrouter,
        model_id: model_id
      }
    end
  end

  def anthropic_api_available?
    return @anthropic_available if defined?(@anthropic_available)

    api_key = RubyLLM.config.anthropic_api_key
    @anthropic_available = api_key.present? && !api_key.start_with?("<")

    unless @anthropic_available
      Rails.logger.warn "[SelectsLlmProvider] Anthropic API key not configured"
    end

    @anthropic_available
  end

  def gemini_model?(model_id)
    model_id.to_s.start_with?("google/")
  end

  def gemini_direct_access_enabled?
    return @gemini_enabled if defined?(@gemini_enabled)

    gemini_key = RubyLLM.config.gemini_api_key
    key_configured = gemini_key.present? && !gemini_key.start_with?("<")
    column_exists = ToolCall.column_names.include?("metadata")

    @gemini_enabled = key_configured && column_exists

    unless @gemini_enabled
      reasons = []
      reasons << "Gemini API key not configured" unless key_configured
      reasons << "metadata column missing from tool_calls" unless column_exists
      Rails.logger.warn "[SelectsLlmProvider] Direct Gemini access disabled: #{reasons.join(', ')}. Falling back to OpenRouter."
    end

    @gemini_enabled
  end

  def normalize_gemini_model_id(model_id)
    model_id.to_s.sub(/^google\//, "")
  end
end
```

---

### Phase 4: Streaming Infrastructure

#### Step 4.1: Create StreamBuffer class
- [ ] Create `app/jobs/concerns/stream_buffer.rb`

```ruby
# frozen_string_literal: true

# A simple buffer for debouncing streamed content.
#
# Accumulates chunks and flushes them after a configurable debounce interval.
# Tracks both the pending buffer and total accumulated content.
class StreamBuffer
  attr_reader :accumulated

  def initialize(debounce: 0.2.seconds)
    @buffer = +""
    @accumulated = +""
    @last_flush_at = nil
    @debounce = debounce
  end

  # Add a chunk to the buffer
  def <<(chunk)
    @buffer << chunk.to_s
    @accumulated << chunk.to_s
  end

  # Flush if the debounce interval has elapsed
  # Returns the flushed content or nil if not yet due
  def flush_if_due
    return nil unless flush_due?
    flush!
  end

  # Force flush the buffer regardless of debounce
  # Returns the flushed content or nil if buffer is empty
  def flush!
    return nil if @buffer.blank?

    chunk = @buffer
    @buffer = +""
    @last_flush_at = Time.current
    chunk
  end

  private

  def flush_due?
    @buffer.present? && (@last_flush_at.nil? || Time.current - @last_flush_at >= @debounce)
  end
end
```

#### Step 4.2: Refactor StreamsAiResponse
- [ ] Update `app/jobs/concerns/streams_ai_response.rb`

Replace the entire file with this version that uses StreamBuffer:

```ruby
# frozen_string_literal: true

require_relative "stream_buffer"

module StreamsAiResponse
  extend ActiveSupport::Concern

  private

  def setup_streaming_state
    @content_buffer = StreamBuffer.new(debounce: 0.2.seconds)
    @thinking_buffer = StreamBuffer.new(debounce: 0.1.seconds)
    @tools_used = []
  end

  def finalize_message!(ruby_llm_message)
    return unless @ai_message

    flush_all_buffers

    @ai_message.update!({
      content: extract_message_content(ruby_llm_message.content),
      thinking: @thinking_buffer.accumulated.presence,
      model_id_string: ruby_llm_message.model_id,
      input_tokens: ruby_llm_message.input_tokens,
      output_tokens: ruby_llm_message.output_tokens,
      tools_used: @tools_used.uniq
    })
  end

  def extract_message_content(content)
    case content
    when RubyLLM::Content
      content.text
    when Hash, Array
      content.to_json
    else
      content
    end
  end

  def enqueue_stream_chunk(chunk)
    @content_buffer << chunk
    if (chunk_to_send = @content_buffer.flush_if_due)
      @ai_message&.stream_content(chunk_to_send)
    end
  end

  def enqueue_thinking_chunk(chunk)
    @thinking_buffer << chunk
    if (chunk_to_send = @thinking_buffer.flush_if_due)
      @ai_message&.stream_thinking(chunk_to_send)
    end
  end

  def flush_all_buffers
    if (chunk = @content_buffer.flush!)
      @ai_message&.stream_content(chunk)
    end
    if (chunk = @thinking_buffer.flush!)
      @ai_message&.stream_thinking(chunk)
    end
  end

  QUIET_TOOLS = %w[
    ViewSystemPromptTool view_system_prompt
    UpdateSystemPromptTool update_system_prompt
  ].freeze

  def handle_tool_call(tool_call)
    tool_name = tool_call.name.to_s
    Rails.logger.info "Tool invoked: #{tool_name} with args: #{tool_call.arguments}"

    url = tool_call.arguments[:url] || tool_call.arguments["url"]
    @tools_used << (url || tool_name)

    return if QUIET_TOOLS.include?(tool_name)

    @ai_message&.broadcast_tool_call(
      tool_name: tool_name,
      tool_args: tool_call.arguments
    )
  end

  def cleanup_streaming
    flush_all_buffers
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end
end
```

---

### Phase 5: Job Updates

#### Step 5.1: Update ManualAgentResponseJob
- [ ] Update `app/jobs/manual_agent_response_job.rb`

Replace the entire file:

```ruby
# frozen_string_literal: true

class ManualAgentResponseJob < ApplicationJob
  include StreamsAiResponse
  include SelectsLlmProvider
  include BroadcastsDebug

  retry_on RubyLLM::ModelNotFoundError, wait: 5.seconds, attempts: 2
  retry_on RubyLLM::BadRequestError, wait: :polynomially_longer, attempts: 3
  retry_on RubyLLM::ServerError, wait: :polynomially_longer, attempts: 3
  retry_on RubyLLM::RateLimitError, wait: :polynomially_longer, attempts: 5
  retry_on Faraday::Error, wait: :polynomially_longer, attempts: 3

  def perform(chat, agent)
    @chat = chat
    @agent = agent
    @ai_message = nil
    setup_streaming_state

    debug_info "Starting response for agent '#{agent.name}' (model: #{agent.model_id})"
    debug_info "Thinking: #{agent.uses_thinking? ? 'enabled' : 'disabled'}"

    # Check for missing API key upfront for thinking-enabled agents
    if agent.uses_thinking? && Chat.requires_direct_api_for_thinking?(agent.model_id) && !anthropic_api_available?
      broadcast_error("Extended thinking requires Anthropic API access, but the API key is not configured.")
      return
    end

    context = chat.build_context_for_agent(agent)
    debug_info "Built context with #{context.length} messages"

    provider_config = llm_provider_for(agent.model_id, thinking_enabled: agent.uses_thinking?)
    debug_info "Using provider: #{provider_config[:provider]}, model: #{provider_config[:model_id]}"

    llm = RubyLLM.chat(
      model: provider_config[:model_id],
      provider: provider_config[:provider],
      assume_model_exists: true
    )

    # Configure thinking if this is an Anthropic direct call with thinking
    if provider_config[:thinking]
      llm = llm.with_params(
        thinking: { type: "enabled", budget_tokens: agent.thinking_budget || 10000 }
      )
      debug_info "Configured Anthropic thinking with budget: #{agent.thinking_budget || 10000}"
    end

    # Tool setup
    tools_added = []
    agent.tools.each do |tool_class|
      tool = tool_class.new(chat: chat, current_agent: agent)
      llm = llm.with_tool(tool)
      tools_added << tool_class.name
    end
    debug_info "Added #{tools_added.length} tools: #{tools_added.join(', ')}" if tools_added.any?

    llm.on_new_message do
      @ai_message&.stop_streaming if @ai_message&.streaming?

      debug_info "Creating new assistant message"
      @ai_message = chat.messages.create!(
        role: "assistant",
        agent: agent,
        content: "",
        thinking: "",
        streaming: true
      )
      debug_info "Message created with ID: #{@ai_message.obfuscated_id}"
    end

    llm.on_tool_call do |tc|
      debug_info "Tool call: #{tc.name}(#{tc.arguments.to_json.truncate(100)})"
      handle_tool_call(tc)
    end

    llm.on_end_message do |msg|
      debug_info "Response complete - #{msg.content&.length || 0} chars"
      finalize_message!(msg)
    end

    debug_info "Sending request to LLM..."
    start_time = Time.current
    context.each { |msg| llm.add_message(msg) }

    llm.complete do |chunk|
      next unless @ai_message

      # Handle thinking chunks (provider-specific)
      if agent.uses_thinking?
        handle_thinking_chunk(chunk, provider_config)
      end

      # Handle content chunks
      if chunk.content.present?
        enqueue_stream_chunk(chunk.content)
      end
    end

    elapsed = ((Time.current - start_time) * 1000).round
    debug_info "LLM request completed in #{elapsed}ms"
  rescue RubyLLM::ModelNotFoundError => e
    debug_error "Model not found: #{e.message}"
    RubyLLM.models.refresh!
    raise
  rescue RubyLLM::BadRequestError, RubyLLM::ServerError, RubyLLM::RateLimitError => e
    debug_error "API error: #{e.message}"
    broadcast_error("AI service error: #{e.message}")
    cleanup_partial_message
    raise
  rescue Faraday::Error => e
    debug_error "Network error: #{e.class.name} - #{e.message}"
    broadcast_error("Network error - please try again")
    cleanup_partial_message
    raise
  rescue StandardError => e
    debug_error "Unexpected error: #{e.class.name} - #{e.message}"
    raise
  ensure
    cleanup_streaming
  end

  private

  def handle_thinking_chunk(chunk, provider_config)
    if provider_config[:provider] == :anthropic
      # Anthropic uses thinking_delta events - check for thinking content
      if chunk.respond_to?(:thinking) && chunk.thinking.present?
        enqueue_thinking_chunk(chunk.thinking)
      end
    else
      # OpenRouter uses reasoning field in delta
      if chunk.respond_to?(:reasoning) && chunk.reasoning.present?
        enqueue_thinking_chunk(chunk.reasoning)
      end
    end
  end

  def broadcast_error(message)
    @chat.broadcast_marker(
      "Chat:#{@chat.to_param}",
      { action: "error", message: message }
    )
  end

  def cleanup_partial_message
    return unless @ai_message&.persisted?
    @ai_message.destroy if @ai_message.content.blank? && @ai_message.streaming?
  end
end
```

#### Step 5.2: Update AllAgentsResponseJob
- [ ] Update `app/jobs/all_agents_response_job.rb` with the same thinking-related changes

The same pattern applies: pass `thinking_enabled: agent.uses_thinking?` to `llm_provider_for`, configure thinking params when `provider_config[:thinking]` is true, and call `handle_thinking_chunk` in the streaming block.

---

### Phase 6: Controller Updates

#### Step 6.1: Update AgentsController
- [ ] Update `app/controllers/agents_controller.rb`

Add thinking parameters to `agent_params`:

```ruby
# In agent_params method
def agent_params
  params.require(:agent).permit(
    :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
    :model_id, :active, :colour, :icon,
    :thinking_enabled, :thinking_budget,
    enabled_tools: []
  )
end
```

Update `grouped_models` to include thinking support flag:

```ruby
def grouped_models
  Chat::MODELS.group_by { |m| m[:group] || "Other" }.transform_values do |models|
    models.map do |m|
      {
        model_id: m[:model_id],
        label: m[:label],
        supports_thinking: m.dig(:thinking, :supported) == true
      }
    end
  end
end
```

---

### Phase 7: Frontend Updates

#### Step 7.1: Update Agent Edit Page
- [ ] Update `app/frontend/pages/agents/edit.svelte`

Add thinking support detection function in the script section:

```javascript
function modelSupportsThinking(modelId) {
  for (const models of Object.values(grouped_models)) {
    const found = models.find((m) => m.model_id === modelId);
    if (found) return found.supports_thinking === true;
  }
  return false;
}
```

Update the form initialization:

```javascript
let form = useForm({
  agent: {
    name: agent.name,
    system_prompt: agent.system_prompt || '',
    reflection_prompt: agent.reflection_prompt || '',
    memory_reflection_prompt: agent.memory_reflection_prompt || '',
    model_id: agent.model_id,
    active: agent.active,
    enabled_tools: agent.enabled_tools || [],
    colour: agent.colour || null,
    icon: agent.icon || null,
    thinking_enabled: agent.thinking_enabled || false,
    thinking_budget: agent.thinking_budget || 10000,
  },
});
```

Add thinking configuration card after the AI Model card:

```svelte
<Card>
  <CardHeader>
    <CardTitle>Extended Thinking</CardTitle>
    <CardDescription>
      Allow the model to show its reasoning process before responding
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    {#if modelSupportsThinking(selectedModel)}
      <div class="flex items-center justify-between">
        <div class="space-y-1">
          <Label for="thinking_enabled">Enable Thinking</Label>
          <p class="text-sm text-muted-foreground">
            Show the model's reasoning process in responses
          </p>
        </div>
        <Switch
          id="thinking_enabled"
          checked={$form.agent.thinking_enabled}
          onCheckedChange={(checked) => ($form.agent.thinking_enabled = checked)} />
      </div>

      {#if $form.agent.thinking_enabled}
        <div class="space-y-2">
          <Label for="thinking_budget">Thinking Budget (tokens)</Label>
          <Input
            id="thinking_budget"
            type="number"
            min={1000}
            max={50000}
            step={1000}
            bind:value={$form.agent.thinking_budget}
            class="max-w-xs" />
          <p class="text-xs text-muted-foreground">
            Maximum tokens for reasoning (1,000 - 50,000)
          </p>
        </div>
      {/if}
    {:else}
      <p class="text-sm text-muted-foreground py-4">
        The selected model does not support extended thinking.
        Choose Claude 4+, GPT-5, or Gemini 3 Pro to enable this feature.
      </p>
    {/if}
  </CardContent>
</Card>
```

#### Step 7.2: Create ThinkingBlock Component
- [ ] Create `app/frontend/lib/components/chat/ThinkingBlock.svelte`

```svelte
<script>
  import { slide } from 'svelte/transition';
  import { Brain } from 'phosphor-svelte';

  let { content = '', isStreaming = false, preview = '' } = $props();
  let expanded = $state(false);

  const displayPreview = $derived(preview || 'Thinking...');
</script>

<div class="mb-3 pb-3 border-b border-border/50">
  <button
    onclick={() => (expanded = !expanded)}
    class="flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground transition-colors w-full text-left"
  >
    <Brain
      size={16}
      weight="duotone"
      class="shrink-0 {isStreaming ? 'animate-pulse text-primary' : ''}" />
    {#if expanded}
      <span class="font-medium">Thinking</span>
      <span class="ml-auto text-xs">Click to collapse</span>
    {:else}
      <span class="truncate italic">{displayPreview}</span>
      <span class="ml-auto text-xs shrink-0">Click to expand</span>
    {/if}
  </button>

  {#if expanded}
    <div
      transition:slide={{ duration: 200 }}
      class="mt-2 pl-6 text-sm text-muted-foreground whitespace-pre-wrap font-mono bg-muted/30 rounded p-3 max-h-64 overflow-y-auto"
    >
      {content}
      {#if isStreaming}
        <span class="animate-pulse">|</span>
      {/if}
    </div>
  {/if}
</div>
```

#### Step 7.3: Update Chat Message Display
- [ ] Update `app/frontend/pages/chats/show.svelte`

Import the ThinkingBlock component:

```javascript
import ThinkingBlock from '$lib/components/chat/ThinkingBlock.svelte';
```

Add thinking streaming state:

```javascript
let streamingThinking = $state({});
```

Update the streamingSync handler to handle thinking_update:

```javascript
streamingSync(
  (data) => {
    if (data.id) {
      const index = messages.findIndex((m) => m.id === data.id);
      if (index !== -1) {
        if (data.action === 'thinking_update') {
          streamingThinking[data.id] = (streamingThinking[data.id] || '') + (data.chunk || '');
        } else if (data.action === 'streaming_update') {
          // Existing content streaming logic
          logging.debug('Updating message via streaming:', data.id, data.chunk);
          const currentMessage = messages[index] || {};
          const updatedMessage = {
            ...currentMessage,
            content: `${currentMessage.content || ''}${data.chunk || ''}`,
            streaming: true,
          };
          messages = messages.map((message, messageIndex) =>
            messageIndex === index ? updatedMessage : message
          );
          setTimeout(() => scrollToBottomIfNeeded(), 0);
        }
      }
    }
  },
  (data) => {
    if (data.id) {
      // Clear streaming thinking on stream end
      if (streamingThinking[data.id]) {
        delete streamingThinking[data.id];
        streamingThinking = { ...streamingThinking };
      }
      // Existing end logic
      const index = messages.findIndex((m) => m.id === data.id);
      if (index !== -1) {
        messages = messages.map((message, messageIndex) =>
          messageIndex === index ? { ...message, streaming: false } : message
        );
      }
    }
  }
);
```

In the assistant message rendering section, add ThinkingBlock before the content:

```svelte
{:else if message.streaming && (!message.content || message.content.trim() === '')}
  <!-- Existing empty streaming state -->
{:else}
  <!-- Add thinking block before content -->
  {#if message.thinking || streamingThinking[message.id]}
    <ThinkingBlock
      content={message.thinking || streamingThinking[message.id] || ''}
      isStreaming={message.streaming && !message.thinking}
      preview={message.thinking_preview} />
  {/if}
  <Streamdown ... />
{/if}
```

#### Step 7.4: Handle Transient Errors
- [ ] Add error state and toast display in `app/frontend/pages/chats/show.svelte`

Add state:

```javascript
let errorMessage = $state(null);
```

Add error subscription in the sync effect or onMount:

```javascript
// In the existing sync subscription setup, handle error action
// This can be added to the SyncChannel received handler
if (data.action === 'error') {
  errorMessage = data.message;
  setTimeout(() => (errorMessage = null), 5000);
}
```

Add error toast display at the end of the template:

```svelte
{#if errorMessage}
  <div
    class="fixed bottom-4 right-4 bg-destructive text-destructive-foreground px-4 py-2 rounded-lg shadow-lg z-50"
    transition:fade
  >
    {errorMessage}
  </div>
{/if}
```

---

### Phase 8: Testing

#### Step 8.1: Unit tests for Chat model class methods
- [ ] Create `test/models/chat_thinking_test.rb`

```ruby
require "test_helper"

class ChatThinkingTest < ActiveSupport::TestCase
  test "supports_thinking? returns true for capable models" do
    assert Chat.supports_thinking?("anthropic/claude-opus-4.5")
    assert Chat.supports_thinking?("openai/gpt-5")
    assert Chat.supports_thinking?("google/gemini-3-pro-preview")
  end

  test "supports_thinking? returns false for non-capable models" do
    refute Chat.supports_thinking?("anthropic/claude-3.5-sonnet")
    refute Chat.supports_thinking?("openai/gpt-4o")
    refute Chat.supports_thinking?("anthropic/claude-haiku-4.5")
  end

  test "requires_direct_api_for_thinking? returns true for Claude 4+ models" do
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-opus-4.5")
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-sonnet-4")
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-opus-4")
  end

  test "requires_direct_api_for_thinking? returns false for non-Claude 4 models" do
    refute Chat.requires_direct_api_for_thinking?("anthropic/claude-3.7-sonnet")
    refute Chat.requires_direct_api_for_thinking?("openai/gpt-5")
    refute Chat.requires_direct_api_for_thinking?("google/gemini-3-pro-preview")
  end

  test "provider_model_id returns correct Anthropic model ID" do
    assert_equal "claude-opus-4-5-20251101", Chat.provider_model_id("anthropic/claude-opus-4.5")
    assert_equal "claude-sonnet-4-20250514", Chat.provider_model_id("anthropic/claude-sonnet-4")
  end

  test "provider_model_id falls back to stripping provider prefix" do
    assert_equal "gpt-5", Chat.provider_model_id("openai/gpt-5")
    assert_equal "gemini-3-pro-preview", Chat.provider_model_id("google/gemini-3-pro-preview")
  end

  test "model_config returns nil for unknown models" do
    assert_nil Chat.model_config("unknown/model")
  end
end
```

#### Step 8.2: Unit tests for Agent thinking
- [ ] Create `test/models/agent_thinking_test.rb`

```ruby
require "test_helper"

class AgentThinkingTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:one)
  end

  test "uses_thinking? returns true when enabled and model supports it" do
    @agent.model_id = "anthropic/claude-opus-4.5"
    @agent.thinking_enabled = true
    assert @agent.uses_thinking?
  end

  test "uses_thinking? returns false when model does not support thinking" do
    @agent.model_id = "anthropic/claude-3.5-sonnet"
    @agent.thinking_enabled = true
    refute @agent.uses_thinking?
  end

  test "uses_thinking? returns false when thinking is disabled" do
    @agent.model_id = "anthropic/claude-opus-4.5"
    @agent.thinking_enabled = false
    refute @agent.uses_thinking?
  end

  test "validates thinking_budget minimum" do
    @agent.thinking_budget = 500
    refute @agent.valid?
    assert @agent.errors[:thinking_budget].any?
  end

  test "validates thinking_budget maximum" do
    @agent.thinking_budget = 100000
    refute @agent.valid?
    assert @agent.errors[:thinking_budget].any?
  end

  test "allows valid thinking_budget" do
    @agent.thinking_budget = 10000
    @agent.valid?
    refute @agent.errors[:thinking_budget].any?
  end

  test "allows nil thinking_budget" do
    @agent.thinking_budget = nil
    @agent.valid?
    refute @agent.errors[:thinking_budget].any?
  end
end
```

#### Step 8.3: Unit tests for StreamBuffer
- [ ] Create `test/jobs/concerns/stream_buffer_test.rb`

```ruby
require "test_helper"
require_relative "../../../app/jobs/concerns/stream_buffer"

class StreamBufferTest < ActiveSupport::TestCase
  test "accumulates all chunks" do
    buffer = StreamBuffer.new
    buffer << "Hello "
    buffer << "World"
    assert_equal "Hello World", buffer.accumulated
  end

  test "flush! returns buffer contents and clears buffer" do
    buffer = StreamBuffer.new
    buffer << "test"
    result = buffer.flush!
    assert_equal "test", result
    assert_nil buffer.flush!
  end

  test "flush! preserves accumulated" do
    buffer = StreamBuffer.new
    buffer << "test"
    buffer.flush!
    assert_equal "test", buffer.accumulated
  end

  test "flush_if_due returns content on first flush" do
    buffer = StreamBuffer.new
    buffer << "test"
    result = buffer.flush_if_due
    assert_equal "test", result
  end

  test "flush_if_due returns nil when debounce not elapsed" do
    buffer = StreamBuffer.new(debounce: 1.second)
    buffer << "test"
    buffer.flush!
    buffer << "more"
    assert_nil buffer.flush_if_due
  end

  test "handles empty chunks gracefully" do
    buffer = StreamBuffer.new
    buffer << ""
    buffer << nil
    buffer << "real"
    assert_equal "real", buffer.accumulated
  end
end
```

#### Step 8.4: Unit tests for Message thinking
- [ ] Add to existing message tests or create `test/models/message_thinking_test.rb`

```ruby
require "test_helper"

class MessageThinkingTest < ActiveSupport::TestCase
  setup do
    @message = messages(:one)
  end

  test "thinking_preview returns nil when thinking is blank" do
    @message.thinking = nil
    assert_nil @message.thinking_preview

    @message.thinking = ""
    assert_nil @message.thinking_preview
  end

  test "thinking_preview truncates to 80 characters" do
    @message.thinking = "a" * 100
    preview = @message.thinking_preview
    assert preview.length <= 80
    assert preview.end_with?("...")
  end

  test "thinking_preview truncates at word boundary" do
    @message.thinking = "This is a test of the thinking preview functionality that should be truncated at a word boundary"
    preview = @message.thinking_preview
    refute preview.include?("boundary") # Should cut before this word
    assert preview.end_with?("...")
  end

  test "json_attributes includes thinking fields" do
    @message.thinking = "Some thinking content"
    json = @message.json_attributes
    assert json.key?("thinking")
    assert json.key?("thinking_preview")
    assert_equal "Some thinking content", json["thinking"]
  end
end
```

---

## Files Changed Summary

| File | Type | Changes |
|------|------|---------|
| `db/migrate/*_add_thinking_to_messages.rb` | New | Add thinking column |
| `db/migrate/*_add_thinking_settings_to_agents.rb` | New | Add agent thinking settings |
| `app/models/chat.rb` | Modified | Extended MODELS with thinking metadata, added class methods |
| `app/models/agent.rb` | Modified | Added `uses_thinking?`, validation, json_attributes |
| `app/models/message.rb` | Modified | Added thinking attributes, streaming, and preview |
| `app/jobs/concerns/stream_buffer.rb` | New | Extracted buffer class |
| `app/jobs/concerns/streams_ai_response.rb` | Modified | Uses StreamBuffer, adds thinking streaming |
| `app/jobs/concerns/selects_llm_provider.rb` | Modified | Data-driven routing, Anthropic support |
| `app/jobs/manual_agent_response_job.rb` | Modified | Thinking parameter handling |
| `app/jobs/all_agents_response_job.rb` | Modified | Same as ManualAgentResponseJob |
| `app/controllers/agents_controller.rb` | Modified | Permit thinking params, enhanced grouped_models |
| `app/frontend/pages/agents/edit.svelte` | Modified | Thinking UI controls |
| `app/frontend/pages/chats/show.svelte` | Modified | Thinking display and streaming |
| `app/frontend/lib/components/chat/ThinkingBlock.svelte` | New | Collapsible thinking component |
| `test/models/chat_thinking_test.rb` | New | Chat model class method tests |
| `test/models/agent_thinking_test.rb` | New | Agent thinking tests |
| `test/models/message_thinking_test.rb` | New | Message thinking tests |
| `test/jobs/concerns/stream_buffer_test.rb` | New | StreamBuffer tests |

---

## Migration Safety

Both migrations are additive with sensible defaults:
- `thinking` column defaults to NULL
- `thinking_enabled` defaults to false
- `thinking_budget` defaults to 10000

No data migration required. Existing conversations and agents continue working unchanged.

---

## Edge Cases and Error Handling

### API Key Not Configured
When an agent with thinking enabled uses a Claude 4+ model but the Anthropic API key is not configured:
- The job checks `anthropic_api_available?` before proceeding
- A transient error is broadcast to the chat UI
- No permanent error message is created in the conversation
- The job returns early without raising (no retries)

### Model Changed After Thinking Enabled
If an agent has `thinking_enabled = true` but the model is later changed to one that does not support thinking:
- `uses_thinking?` returns false (thinking disabled && supported check)
- The agent works normally without thinking
- No error is shown

### Streaming Failures
If streaming fails mid-response:
- `cleanup_streaming` flushes any remaining buffers
- `cleanup_partial_message` removes empty streaming messages
- Transient error is broadcast to UI
- Job retries per the `retry_on` configuration

### Large Thinking Content
- Thinking is stored in a TEXT column (no size limit in PostgreSQL)
- Preview is truncated to 80 characters for UI display
- Full thinking is displayed in expandable section (scrollable, max-height)

### Concurrent Editing
- Whiteboard conflict handling is already implemented
- Thinking updates use `update_columns` to bypass callbacks (like content streaming)
- No special concurrency handling needed for thinking

---

## Implementation Order

For the smoothest implementation, follow this order:

1. **Phase 1**: Run migrations first (enables all model changes)
2. **Phase 2**: Update models (Chat, Agent, Message) - core logic
3. **Phase 3**: Update SelectsLlmProvider - routing logic
4. **Phase 4**: Create StreamBuffer and update StreamsAiResponse - streaming infrastructure
5. **Phase 5**: Update job files - ties backend together
6. **Phase 6**: Update controller - enables frontend data
7. **Phase 7**: Update frontend - user-facing features
8. **Phase 8**: Add tests - verify everything works

Run tests after each phase to catch issues early:
```bash
rails test
```

---

## Verification Checklist

After implementation, verify:

- [ ] Agent edit page shows thinking toggle only for supported models
- [ ] Thinking budget input appears when toggle is enabled
- [ ] Claude 4+ agent with thinking routes to Anthropic direct API
- [ ] GPT-5 agent with thinking routes to OpenRouter with reasoning
- [ ] Thinking content streams in real-time to chat UI
- [ ] ThinkingBlock appears collapsed with preview
- [ ] Clicking ThinkingBlock expands to show full thinking
- [ ] Thinking is saved to database and persists on page reload
- [ ] Error toast appears when Anthropic API key is missing
- [ ] Existing agents and chats continue to work unchanged
