# Implementation Plan: Extended Thinking for AI Agents (Revised)

**Date**: 2026-01-01
**Spec**: 260101-02b-thinking
**Requirements**: `/docs/requirements/260101-02-thinking.md`
**Previous iteration**: `/docs/plans/260101-02a-thinking.md`
**Feedback addressed**: `/docs/plans/260101-02a-thinking-dhh-feedback.md`

## Executive Summary

This revised plan implements extended thinking (reasoning) support for AI agents. The key changes from the first iteration address DHH's feedback:

1. **Single source of truth for models** - Extended `Chat::MODELS` with capability metadata instead of duplicating lists
2. **Data-driven provider routing** - `SelectsLlmProvider` routes based on model metadata, not cascading conditionals
3. **Extracted StreamBuffer class** - Eliminates instance variable bloat and duplicated buffer logic
4. **Cleaner naming** - `uses_thinking?` instead of `thinking_enabled_and_supported?`
5. **Transient error handling** - API errors broadcast to UI instead of creating permanent error messages

## Architecture Overview

The design follows the "single source of truth" principle. Model capabilities live in one place, and everything else derives from that data.

```
Chat::MODELS (single source of truth)
       │
       ├── Agent.uses_thinking? (derived)
       ├── SelectsLlmProvider.llm_provider_for (derived)
       └── Frontend grouped_models (derived via controller)

StreamBuffer (extracted class)
       │
       ├── @content_buffer (StreamsAiResponse)
       └── @thinking_buffer (StreamsAiResponse)
```

## Implementation Steps

### Phase 1: Database Changes

#### Step 1.1: Add thinking column to messages
- [ ] Create migration to add `thinking` text column

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_thinking_to_messages.rb
class AddThinkingToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :thinking, :text
  end
end
```

#### Step 1.2: Add thinking settings to agents
- [ ] Create migration to add thinking columns

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_thinking_settings_to_agents.rb
class AddThinkingSettingsToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :thinking_enabled, :boolean, default: false, null: false
    add_column :agents, :thinking_budget, :integer, default: 10000
  end
end
```

### Phase 2: Model Capabilities - Single Source of Truth

#### Step 2.1: Extend Chat::MODELS with capability metadata
- [ ] Add `thinking` metadata to each model entry

Replace the existing `MODELS` constant in `app/models/chat.rb`:

```ruby
# In app/models/chat.rb

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

# Model lookup helpers (class methods)
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

#### Step 2.2: Update Agent model
- [ ] Add `uses_thinking?` method that derives from Chat::MODELS
- [ ] Add thinking_budget validation
- [ ] Add thinking attributes to json_attributes

```ruby
# In app/models/agent.rb

validates :thinking_budget,
          numericality: { greater_than_or_equal_to: 1000, less_than_or_equal_to: 50000 },
          allow_nil: true

json_attributes :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
                :model_id, :model_label, :enabled_tools, :active?, :colour, :icon,
                :memories_count, :thinking_enabled, :thinking_budget

def uses_thinking?
  thinking_enabled? && Chat.supports_thinking?(model_id)
end
```

#### Step 2.3: Update Message model
- [ ] Add thinking to json_attributes
- [ ] Add `stream_thinking` method
- [ ] Add `thinking_preview` method

```ruby
# In app/models/message.rb

json_attributes :role, :content, :thinking, :thinking_preview, :user_name, :user_avatar_url,
                :completed, :created_at_formatted, :created_at_hour, :streaming,
                :files_json, :content_html, :tools_used, :tool_status,
                :author_name, :author_type, :author_colour, :input_tokens, :output_tokens

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

### Phase 3: Provider Routing - Data-Driven

#### Step 3.1: Refactor SelectsLlmProvider
- [ ] Replace conditional cascade with model metadata lookup
- [ ] Add Anthropic direct API routing for thinking

```ruby
# app/jobs/concerns/selects_llm_provider.rb

module SelectsLlmProvider
  extend ActiveSupport::Concern

  private

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

  # Existing Gemini methods unchanged
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
      Rails.logger.warn "[SelectsLlmProvider] Direct Gemini access disabled: #{reasons.join(', ')}."
    end

    @gemini_enabled
  end

  def normalize_gemini_model_id(model_id)
    model_id.to_s.sub(/^google\//, "")
  end
end
```

### Phase 4: Streaming - Extract StreamBuffer

#### Step 4.1: Create StreamBuffer class
- [ ] Extract buffer logic into a focused class

```ruby
# app/jobs/concerns/stream_buffer.rb

class StreamBuffer
  attr_reader :accumulated

  def initialize(debounce: 0.2.seconds)
    @buffer = +""
    @accumulated = +""
    @last_flush_at = nil
    @debounce = debounce
  end

  def <<(chunk)
    @buffer << chunk.to_s
    @accumulated << chunk.to_s
  end

  def flush_if_due
    return nil unless flush_due?
    flush!
  end

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
- [ ] Use StreamBuffer for both content and thinking
- [ ] Reduce instance variables from 7 to 3

```ruby
# app/jobs/concerns/streams_ai_response.rb

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
    if chunk_to_send = @content_buffer.flush_if_due
      @ai_message&.stream_content(chunk_to_send)
    end
  end

  def enqueue_thinking_chunk(chunk)
    @thinking_buffer << chunk
    if chunk_to_send = @thinking_buffer.flush_if_due
      @ai_message&.stream_thinking(chunk_to_send)
    end
  end

  def flush_all_buffers
    if chunk = @content_buffer.flush!
      @ai_message&.stream_content(chunk)
    end
    if chunk = @thinking_buffer.flush!
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

### Phase 5: Job Changes

#### Step 5.1: Update ManualAgentResponseJob
- [ ] Pass thinking_enabled to provider selection
- [ ] Configure RubyLLM with thinking parameters
- [ ] Handle thinking chunks from both providers

```ruby
# app/jobs/manual_agent_response_job.rb

def perform(chat, agent)
  @chat = chat
  @agent = agent
  @ai_message = nil
  setup_streaming_state

  debug_info "Starting response for agent '#{agent.name}' (model: #{agent.model_id})"
  debug_info "Thinking: #{agent.uses_thinking? ? 'enabled' : 'disabled'}"

  # Check for missing API key upfront
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

  # Tool setup (unchanged)
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
    # Anthropic uses thinking_delta events
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
  # Broadcast transient error to chat - no permanent message created
  @chat.broadcast_marker(
    "Chat:#{@chat.to_param}",
    { action: "error", message: message }
  )
end

def cleanup_partial_message
  return unless @ai_message&.persisted?
  @ai_message.destroy if @ai_message.content.blank? && @ai_message.streaming?
end
```

#### Step 5.2: Update AllAgentsResponseJob
- [ ] Apply the same thinking-related changes

The `AllAgentsResponseJob` should receive the same updates for thinking support. Since both jobs use the `StreamsAiResponse` and `SelectsLlmProvider` concerns, most of the logic is shared.

### Phase 6: Controller Changes

#### Step 6.1: Update AgentsController
- [ ] Add thinking parameters to agent_params
- [ ] Pass thinking capability metadata in grouped_models

```ruby
# app/controllers/agents_controller.rb

def agent_params
  params.require(:agent).permit(
    :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
    :model_id, :active, :colour, :icon,
    :thinking_enabled, :thinking_budget,
    enabled_tools: []
  )
end

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

### Phase 7: Frontend Changes

#### Step 7.1: Update Agent Edit Page
- [ ] Add thinking toggle (shown only for supported models)
- [ ] Add thinking budget input
- [ ] Derive thinking support from grouped_models data

```svelte
<!-- In app/frontend/pages/agents/edit.svelte -->
<!-- Add after AI Model card -->

<script>
  // Add to existing script section
  function modelSupportsThinking(modelId) {
    for (const models of Object.values(grouped_models)) {
      const found = models.find((m) => m.model_id === modelId);
      if (found) return found.supports_thinking === true;
    }
    return false;
  }
</script>

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

Also add to the form initialization:

```javascript
let form = useForm({
  agent: {
    // ... existing fields
    thinking_enabled: agent.thinking_enabled || false,
    thinking_budget: agent.thinking_budget || 10000,
  },
});
```

#### Step 7.2: Create ThinkingBlock Component
- [ ] Create collapsible thinking display component

```svelte
<!-- app/frontend/lib/components/chat/ThinkingBlock.svelte -->
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
- [ ] Add thinking section to assistant messages
- [ ] Handle thinking_update streaming events

```svelte
<!-- In app/frontend/pages/chats/show.svelte -->
<!-- Add state for streaming thinking -->

<script>
  import ThinkingBlock from '$lib/components/chat/ThinkingBlock.svelte';

  let streamingThinking = $state({});

  // In streamingSync handler, add thinking_update case:
  streamingSync(
    (data) => {
      if (data.id) {
        const index = messages.findIndex((m) => m.id === data.id);
        if (index !== -1) {
          if (data.action === 'thinking_update') {
            streamingThinking[data.id] = (streamingThinking[data.id] || '') + (data.chunk || '');
          } else if (data.action === 'streaming_update') {
            // Existing content streaming logic
          }
        }
      }
    },
    (data) => {
      // On stream end, clear streaming thinking
      if (data.id && streamingThinking[data.id]) {
        delete streamingThinking[data.id];
        streamingThinking = { ...streamingThinking };
      }
      // Existing end logic...
    }
  );
</script>

<!-- In assistant message rendering -->
{#if message.thinking || streamingThinking[message.id]}
  <ThinkingBlock
    content={message.thinking || streamingThinking[message.id] || ''}
    isStreaming={message.streaming && !message.thinking}
    preview={message.thinking_preview} />
{/if}
```

#### Step 7.4: Handle Transient Errors
- [ ] Add error state and handler for broadcast errors

```svelte
<script>
  let errorMessage = $state(null);

  // Subscribe to chat errors
  onMount(() => {
    const channel = cable.subscriptions.create(
      { channel: 'SyncChannel', syncable_type: 'Chat', syncable_id: chat.id },
      {
        received(data) {
          if (data.action === 'error') {
            errorMessage = data.message;
            setTimeout(() => errorMessage = null, 5000);
          }
        }
      }
    );
    return () => channel.unsubscribe();
  });
</script>

{#if errorMessage}
  <div class="fixed bottom-4 right-4 bg-destructive text-destructive-foreground px-4 py-2 rounded-lg shadow-lg">
    {errorMessage}
  </div>
{/if}
```

### Phase 8: Testing

#### Step 8.1: Unit tests for Chat model class methods
- [ ] Test `supports_thinking?`
- [ ] Test `requires_direct_api_for_thinking?`
- [ ] Test `provider_model_id`

```ruby
# test/models/chat_thinking_test.rb
class ChatThinkingTest < ActiveSupport::TestCase
  test "supports_thinking? returns true for capable models" do
    assert Chat.supports_thinking?("anthropic/claude-opus-4.5")
    assert Chat.supports_thinking?("openai/gpt-5")
    refute Chat.supports_thinking?("anthropic/claude-3.5-sonnet")
  end

  test "requires_direct_api_for_thinking? returns true for Claude 4+ models" do
    assert Chat.requires_direct_api_for_thinking?("anthropic/claude-opus-4.5")
    refute Chat.requires_direct_api_for_thinking?("anthropic/claude-3.7-sonnet")
    refute Chat.requires_direct_api_for_thinking?("openai/gpt-5")
  end

  test "provider_model_id returns correct Anthropic model ID" do
    assert_equal "claude-opus-4-5-20251101", Chat.provider_model_id("anthropic/claude-opus-4.5")
    assert_equal "gpt-5", Chat.provider_model_id("openai/gpt-5")
  end
end
```

#### Step 8.2: Unit tests for Agent thinking
- [ ] Test `uses_thinking?` method
- [ ] Test thinking_budget validation

```ruby
# test/models/agent_thinking_test.rb
class AgentThinkingTest < ActiveSupport::TestCase
  test "uses_thinking? returns true when enabled and model supports it" do
    agent = agents(:one)
    agent.model_id = "anthropic/claude-opus-4.5"
    agent.thinking_enabled = true
    assert agent.uses_thinking?
  end

  test "uses_thinking? returns false when model does not support thinking" do
    agent = agents(:one)
    agent.model_id = "anthropic/claude-3.5-sonnet"
    agent.thinking_enabled = true
    refute agent.uses_thinking?
  end

  test "validates thinking_budget range" do
    agent = agents(:one)
    agent.thinking_budget = 500
    refute agent.valid?
    assert agent.errors[:thinking_budget].any?

    agent.thinking_budget = 10000
    assert agent.valid?
  end
end
```

#### Step 8.3: Unit tests for StreamBuffer
- [ ] Test debounce behavior
- [ ] Test accumulation

```ruby
# test/jobs/concerns/stream_buffer_test.rb
require "test_helper"
require_relative "../../../app/jobs/concerns/stream_buffer"

class StreamBufferTest < ActiveSupport::TestCase
  test "accumulates all chunks" do
    buffer = StreamBuffer.new
    buffer << "Hello "
    buffer << "World"
    assert_equal "Hello World", buffer.accumulated
  end

  test "flush_if_due returns nil when debounce not elapsed" do
    buffer = StreamBuffer.new(debounce: 1.second)
    buffer << "test"
    buffer.flush!
    buffer << "more"
    assert_nil buffer.flush_if_due
  end

  test "flush! returns buffer contents and clears buffer" do
    buffer = StreamBuffer.new
    buffer << "test"
    result = buffer.flush!
    assert_equal "test", result
    assert_nil buffer.flush!
  end
end
```

#### Step 8.4: Integration tests for provider routing
- [ ] Test that thinking routes to correct provider

```ruby
# test/jobs/provider_routing_test.rb
class ProviderRoutingTest < ActiveSupport::TestCase
  include SelectsLlmProvider

  test "routes Claude 4+ with thinking to Anthropic direct" do
    # Mock anthropic_api_available? to return true
    config = llm_provider_for("anthropic/claude-opus-4.5", thinking_enabled: true)

    if anthropic_api_available?
      assert_equal :anthropic, config[:provider]
      assert config[:thinking]
    else
      assert_equal :openrouter, config[:provider]
    end
  end

  test "routes Claude 4+ without thinking to OpenRouter" do
    config = llm_provider_for("anthropic/claude-opus-4.5", thinking_enabled: false)
    assert_equal :openrouter, config[:provider]
    refute config[:thinking]
  end
end
```

## Files Changed Summary

| File | Type | Changes |
|------|------|---------|
| `db/migrate/*_add_thinking_to_messages.rb` | New | Add thinking column |
| `db/migrate/*_add_thinking_settings_to_agents.rb` | New | Add agent thinking settings |
| `app/models/chat.rb` | Modified | Extended MODELS with thinking metadata, added class methods |
| `app/models/agent.rb` | Modified | Added `uses_thinking?`, validation, json_attributes |
| `app/models/message.rb` | Modified | Added thinking attributes and streaming |
| `app/jobs/concerns/stream_buffer.rb` | New | Extracted buffer class |
| `app/jobs/concerns/streams_ai_response.rb` | Modified | Uses StreamBuffer, adds thinking streaming |
| `app/jobs/concerns/selects_llm_provider.rb` | Modified | Data-driven routing, Anthropic support |
| `app/jobs/manual_agent_response_job.rb` | Modified | Thinking parameter handling |
| `app/jobs/all_agents_response_job.rb` | Modified | Same as ManualAgentResponseJob |
| `app/controllers/agents_controller.rb` | Modified | Permit thinking params, enhanced grouped_models |
| `app/frontend/pages/agents/edit.svelte` | Modified | Thinking UI controls |
| `app/frontend/pages/chats/show.svelte` | Modified | Thinking display and streaming |
| `app/frontend/lib/components/chat/ThinkingBlock.svelte` | New | Collapsible thinking component |

## Key Improvements Over Previous Spec

1. **DRY Model Metadata**: Single `Chat::MODELS` definition with thinking capabilities. No duplicate lists in Agent or JavaScript.

2. **Cleaner Provider Routing**: `SelectsLlmProvider` now queries model metadata instead of maintaining separate lists and cascading conditionals.

3. **StreamBuffer Extraction**: Reduces `StreamsAiResponse` from 7 instance variables to 3, eliminates duplicated buffer logic, and makes streaming testable in isolation.

4. **Natural Naming**: `uses_thinking?` reads like English rather than `thinking_enabled_and_supported?`.

5. **Transient Errors**: API failures broadcast to UI instead of creating permanent error messages in the conversation.

6. **Frontend Derives from Server**: `supports_thinking` flag comes from server via `grouped_models`, not a hardcoded JavaScript list.

## Migration Safety

Both migrations are additive with sensible defaults:
- `thinking` column defaults to NULL
- `thinking_enabled` defaults to false
- `thinking_budget` defaults to 10000

No data migration required. Existing conversations and agents continue working unchanged.
