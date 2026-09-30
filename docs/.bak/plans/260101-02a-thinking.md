# Implementation Plan: Extended Thinking for AI Agents

**Date**: 2026-01-01
**Spec**: 260101-02a-thinking
**Requirements**: `/docs/requirements/260101-02-thinking.md`

## Executive Summary

This plan implements extended thinking (reasoning) support for AI agents, allowing users to see the model's internal reasoning process before the final response. The implementation covers:

1. Database changes to store thinking content separately from response content
2. Agent configuration UI for enabling thinking and setting token budgets
3. Provider routing to use Anthropic direct API for Claude 4+ models
4. Streaming handler modifications to capture both thinking and text deltas
5. Frontend display with collapsible thinking sections inside message bubbles

The key technical challenge is handling two fundamentally different thinking formats:
- **Anthropic Direct API** (Claude 4+): Separate content blocks with `type: "thinking"` and streaming `thinking_delta` events
- **OpenRouter** (GPT-5, Gemini, Claude 3.7): `reasoning` field in streaming deltas

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Agent Configuration                          │
│  ┌─────────────────┐  ┌─────────────────┐  ┌───────────────────┐   │
│  │ thinking_enabled │  │ thinking_budget  │  │ Model Selection   │   │
│  │    (boolean)     │  │   (integer)      │  │ (determines API)  │   │
│  └────────┬────────┘  └────────┬────────┘  └─────────┬─────────┘   │
└───────────┼────────────────────┼────────────────────┼───────────────┘
            │                    │                    │
            ▼                    ▼                    ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     SelectsLlmProvider Concern                       │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Claude 4+ with thinking → Anthropic Direct API              │    │
│  │ Other thinking models → OpenRouter (unchanged)              │    │
│  │ Non-thinking models → OpenRouter (unchanged)                │    │
│  └─────────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                     StreamsAiResponse Concern                        │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ setup_streaming_state:                                       │    │
│  │   @thinking_buffer = ""                                      │    │
│  │   @in_thinking_block = false                                 │    │
│  │                                                               │    │
│  │ enqueue_thinking_chunk(chunk) → accumulates to buffer        │    │
│  │ flush_thinking_buffer → streams thinking to message          │    │
│  │                                                               │    │
│  │ finalize_message!:                                           │    │
│  │   saves thinking content to message.thinking column          │    │
│  └─────────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          Message Model                               │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ content  → final response text                               │    │
│  │ thinking → reasoning/thinking content (new column)           │    │
│  │                                                               │    │
│  │ stream_thinking(chunk) → broadcasts thinking updates         │    │
│  │ thinking_preview → first ~50 chars for collapsed display     │    │
│  └─────────────────────────────────────────────────────────────┘    │
└───────────────────────────────────────────────────────────────────┘
            │
            ▼
┌─────────────────────────────────────────────────────────────────────┐
│                      Frontend (show.svelte)                          │
│  ┌─────────────────────────────────────────────────────────────┐    │
│  │ Message Bubble:                                              │    │
│  │ ┌─────────────────────────────────────────────────────────┐  │    │
│  │ │ [💭 "Let me think about..."]  ▼ (collapsed)             │  │    │
│  │ └─────────────────────────────────────────────────────────┘  │    │
│  │ ┌─────────────────────────────────────────────────────────┐  │    │
│  │ │ [Final response content...]                             │  │    │
│  │ └─────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────────┘
```

## Implementation Steps

### Phase 1: Database & Model Changes

#### Step 1.1: Add thinking column to messages
- [ ] Create migration to add `thinking` text column to messages table

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_thinking_to_messages.rb
class AddThinkingToMessages < ActiveRecord::Migration[8.1]
  def change
    add_column :messages, :thinking, :text
  end
end
```

#### Step 1.2: Add thinking settings to agents
- [ ] Create migration to add thinking columns to agents table

```ruby
# db/migrate/YYYYMMDDHHMMSS_add_thinking_settings_to_agents.rb
class AddThinkingSettingsToAgents < ActiveRecord::Migration[8.1]
  def change
    add_column :agents, :thinking_enabled, :boolean, default: false, null: false
    add_column :agents, :thinking_budget, :integer, default: 10000
  end
end
```

#### Step 1.3: Update Message model
- [ ] Add `thinking` to json_attributes in Message model
- [ ] Add `thinking_preview` method for collapsed display
- [ ] Add `stream_thinking` method for real-time updates

```ruby
# In app/models/message.rb

json_attributes :role, :content, :thinking, :thinking_preview, # ... rest of existing attributes

def thinking_preview
  return nil if thinking.blank?
  thinking.truncate(80, separator: ' ')
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

#### Step 1.4: Update Agent model
- [ ] Add validations for thinking_budget
- [ ] Add `thinking_enabled` and `thinking_budget` to json_attributes
- [ ] Add `supports_thinking?` class method to check model compatibility

```ruby
# In app/models/agent.rb

THINKING_CAPABLE_MODELS = [
  "anthropic/claude-opus-4.5",
  "anthropic/claude-sonnet-4.5",
  "anthropic/claude-opus-4",
  "anthropic/claude-sonnet-4",
  "anthropic/claude-3.7-sonnet",
  "openai/gpt-5.2",
  "openai/gpt-5.1",
  "openai/gpt-5",
  "google/gemini-3-pro-preview"
].freeze

ANTHROPIC_DIRECT_THINKING_MODELS = [
  "anthropic/claude-opus-4.5",
  "anthropic/claude-sonnet-4.5",
  "anthropic/claude-opus-4",
  "anthropic/claude-sonnet-4"
].freeze

validates :thinking_budget,
          numericality: {
            greater_than_or_equal_to: 1000,
            less_than_or_equal_to: 50000
          },
          allow_nil: true

json_attributes :name, :system_prompt, # ... existing attributes,
                :thinking_enabled, :thinking_budget

def self.supports_thinking?(model_id)
  THINKING_CAPABLE_MODELS.include?(model_id)
end

def self.requires_anthropic_direct?(model_id)
  ANTHROPIC_DIRECT_THINKING_MODELS.include?(model_id)
end

def thinking_enabled_and_supported?
  thinking_enabled? && self.class.supports_thinking?(model_id)
end
```

### Phase 2: Provider Routing Changes

#### Step 2.1: Update SelectsLlmProvider concern
- [ ] Add logic to route Claude 4+ thinking requests to Anthropic direct
- [ ] Add helper methods for checking Anthropic API availability

```ruby
# app/jobs/concerns/selects_llm_provider.rb

module SelectsLlmProvider
  extend ActiveSupport::Concern

  private

  def llm_provider_for(model_id, thinking_enabled: false)
    if thinking_enabled && anthropic_direct_thinking_model?(model_id) && anthropic_direct_access_enabled?
      {
        provider: :anthropic,
        model_id: normalize_anthropic_model_id(model_id),
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

  def anthropic_direct_thinking_model?(model_id)
    Agent::ANTHROPIC_DIRECT_THINKING_MODELS.include?(model_id.to_s)
  end

  def anthropic_direct_access_enabled?
    return @anthropic_enabled if defined?(@anthropic_enabled)

    anthropic_key = RubyLLM.config.anthropic_api_key
    @anthropic_enabled = anthropic_key.present? && !anthropic_key.start_with?("<")

    unless @anthropic_enabled
      Rails.logger.warn "[SelectsLlmProvider] Anthropic direct access disabled: API key not configured"
    end

    @anthropic_enabled
  end

  def normalize_anthropic_model_id(model_id)
    # Convert "anthropic/claude-opus-4.5" to Anthropic's model ID format
    case model_id.to_s
    when "anthropic/claude-opus-4.5"
      "claude-opus-4-5-20251101"
    when "anthropic/claude-sonnet-4.5"
      "claude-sonnet-4-5-20251201"
    when "anthropic/claude-opus-4"
      "claude-opus-4-20250514"
    when "anthropic/claude-sonnet-4"
      "claude-sonnet-4-20250514"
    else
      model_id.to_s.sub(/^anthropic\//, "")
    end
  end

  # ... existing gemini methods unchanged
end
```

### Phase 3: Streaming Handler Changes

#### Step 3.1: Update StreamsAiResponse concern
- [ ] Add thinking buffer and state tracking
- [ ] Add methods for streaming thinking content
- [ ] Update finalize_message! to save thinking

```ruby
# app/jobs/concerns/streams_ai_response.rb

module StreamsAiResponse
  extend ActiveSupport::Concern

  STREAM_DEBOUNCE_INTERVAL = 0.2.seconds
  THINKING_DEBOUNCE_INTERVAL = 0.1.seconds  # Faster updates for thinking

  private

  def setup_streaming_state
    @stream_buffer = +""
    @thinking_buffer = +""
    @last_stream_flush_at = nil
    @last_thinking_flush_at = nil
    @tools_used = []
    @in_thinking_phase = false
    @accumulated_thinking = +""
  end

  def finalize_message!(ruby_llm_message)
    return unless @ai_message

    flush_stream_buffer(force: true)
    flush_thinking_buffer(force: true)

    final_content = extract_message_content(ruby_llm_message.content)
    final_thinking = extract_thinking_content(ruby_llm_message)

    @ai_message.update!({
      content: final_content,
      thinking: final_thinking.presence || @accumulated_thinking.presence,
      model_id_string: ruby_llm_message.model_id,
      input_tokens: ruby_llm_message.input_tokens,
      output_tokens: ruby_llm_message.output_tokens,
      tools_used: @tools_used.uniq
    })
  end

  def extract_thinking_content(ruby_llm_message)
    content = ruby_llm_message.content
    return nil unless content.is_a?(RubyLLM::Content)

    # For Anthropic responses with content blocks
    if content.respond_to?(:blocks)
      thinking_blocks = content.blocks.select { |b| b[:type] == "thinking" }
      return thinking_blocks.map { |b| b[:thinking] }.join("\n") if thinking_blocks.any?
    end

    nil
  end

  def enqueue_thinking_chunk(chunk_content)
    @thinking_buffer << chunk_content.to_s
    @accumulated_thinking << chunk_content.to_s
    flush_thinking_buffer if thinking_flush_due?
  end

  def flush_thinking_buffer(force: false)
    return if @thinking_buffer.blank?
    return unless @ai_message
    return unless force || thinking_flush_due?

    chunk = @thinking_buffer
    @thinking_buffer = +""
    @last_thinking_flush_at = Time.current
    @ai_message.stream_thinking(chunk)
  end

  def thinking_flush_due?
    return true unless @last_thinking_flush_at
    Time.current - @last_thinking_flush_at >= THINKING_DEBOUNCE_INTERVAL
  end

  # ... existing methods unchanged

  def cleanup_streaming
    flush_stream_buffer(force: true)
    flush_thinking_buffer(force: true)
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end
end
```

### Phase 4: Job Changes

#### Step 4.1: Update ManualAgentResponseJob
- [ ] Pass thinking_enabled flag to provider selection
- [ ] Configure RubyLLM with thinking parameters when enabled
- [ ] Handle different streaming formats

```ruby
# app/jobs/manual_agent_response_job.rb

def perform(chat, agent)
  @chat = chat
  @agent = agent
  @ai_message = nil
  setup_streaming_state

  debug_info "Starting response for agent '#{agent.name}' (model: #{agent.model_id})"
  debug_info "Thinking enabled: #{agent.thinking_enabled_and_supported?}"

  context = chat.build_context_for_agent(agent)

  provider_config = llm_provider_for(
    agent.model_id,
    thinking_enabled: agent.thinking_enabled_and_supported?
  )
  debug_info "Using provider: #{provider_config[:provider]}, model: #{provider_config[:model_id]}"

  llm = RubyLLM.chat(
    model: provider_config[:model_id],
    provider: provider_config[:provider],
    assume_model_exists: true
  )

  # Configure thinking if enabled and supported
  if agent.thinking_enabled_and_supported?
    if provider_config[:thinking]
      # Anthropic direct API thinking
      llm = llm.with_params(
        thinking: { type: "enabled", budget_tokens: agent.thinking_budget || 10000 }
      )
      debug_info "Configured Anthropic thinking with budget: #{agent.thinking_budget}"
    end
    # For OpenRouter models, thinking/reasoning is automatic
  end

  # ... rest of existing tool setup and callbacks

  llm.on_new_message do
    @ai_message&.stop_streaming if @ai_message&.streaming?

    debug_info "Creating new assistant message"
    @ai_message = chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: "",
      thinking: "",  # Initialize thinking column
      streaming: true
    )
  end

  # ... existing callbacks

  context.each { |msg| llm.add_message(msg) }
  llm.complete do |chunk|
    next unless @ai_message

    # Handle thinking/reasoning chunks based on provider
    if provider_config[:thinking] || agent.thinking_enabled_and_supported?
      handle_thinking_chunk(chunk, provider_config)
    end

    # Handle content chunks
    if chunk.content.present?
      enqueue_stream_chunk(chunk.content)
    end
  end

  # ... rest of existing error handling
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
```

#### Step 4.2: Update AllAgentsResponseJob
- [ ] Apply same changes as ManualAgentResponseJob (share code via concern)

The streaming/thinking logic should be extracted into a shared method in `StreamsAiResponse` concern, then both jobs can use it. See the pattern above.

### Phase 5: Frontend Changes

#### Step 5.1: Update Agent Edit Page
- [ ] Add thinking toggle (only shown for supported models)
- [ ] Add thinking budget slider/input
- [ ] Show model compatibility message

```svelte
<!-- In app/frontend/pages/agents/edit.svelte -->
<!-- Add after the AI Model card -->

<Card>
  <CardHeader>
    <CardTitle>Extended Thinking</CardTitle>
    <CardDescription>
      Allow the model to show its reasoning process before responding
    </CardDescription>
  </CardHeader>
  <CardContent class="space-y-4">
    {#if supportsThinking(selectedModel)}
      <div class="flex items-center justify-between">
        <div class="space-y-1">
          <Label for="thinking_enabled">Enable Thinking</Label>
          <p class="text-sm text-muted-foreground">
            Show the model's reasoning process
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
            Maximum tokens the model can use for reasoning (1,000 - 50,000)
          </p>
        </div>
      {/if}
    {:else}
      <p class="text-sm text-muted-foreground py-4">
        The selected model ({findModelLabel(selectedModel)}) does not support extended thinking.
        Switch to Claude 4+, GPT-5, or Gemini 3 Pro to enable this feature.
      </p>
    {/if}
  </CardContent>
</Card>
```

Add the helper function:

```javascript
const THINKING_CAPABLE_MODELS = [
  'anthropic/claude-opus-4.5',
  'anthropic/claude-sonnet-4.5',
  'anthropic/claude-opus-4',
  'anthropic/claude-sonnet-4',
  'anthropic/claude-3.7-sonnet',
  'openai/gpt-5.2',
  'openai/gpt-5.1',
  'openai/gpt-5',
  'google/gemini-3-pro-preview'
];

function supportsThinking(modelId) {
  return THINKING_CAPABLE_MODELS.includes(modelId);
}
```

#### Step 5.2: Update Agent Controller
- [ ] Add thinking parameters to agent_params

```ruby
# app/controllers/agents_controller.rb

def agent_params
  params.require(:agent).permit(
    :name, :system_prompt, :reflection_prompt, :memory_reflection_prompt,
    :model_id, :active, :colour, :icon,
    :thinking_enabled, :thinking_budget,  # Add these
    enabled_tools: []
  )
end
```

#### Step 5.3: Update Chat Message Display
- [ ] Add collapsible thinking section to message bubbles
- [ ] Handle thinking streaming updates
- [ ] Add thought bubble icon

```svelte
<!-- In app/frontend/pages/chats/show.svelte -->
<!-- Update the assistant message rendering -->

{:else if message.role === 'assistant'}
  <div class="flex justify-start">
    <div class="max-w-[85%] md:max-w-[70%]">
      <Card.Root class={getBubbleClass(message.author_colour)}>
        <Card.Content class="p-4">
          <!-- Thinking section (collapsible) -->
          {#if message.thinking || (message.streaming && streamingThinking[message.id])}
            {@const thinkingContent = message.thinking || streamingThinking[message.id] || ''}
            <ThinkingBlock
              content={thinkingContent}
              isStreaming={message.streaming && !message.thinking}
              preview={message.thinking_preview} />
          {/if}

          <!-- Rest of existing message content rendering -->
          {#if message.streaming && (!message.content || message.content.trim() === '')}
            <!-- ... existing streaming placeholder ... -->
          {:else}
            <Streamdown ... />
          {/if}

          <!-- ... tools_used section ... -->
        </Card.Content>
      </Card.Root>
    </div>
  </div>
{/if}
```

#### Step 5.4: Create ThinkingBlock component
- [ ] Create new component for collapsible thinking display

```svelte
<!-- app/frontend/lib/components/chat/ThinkingBlock.svelte -->
<script>
  import { slide } from 'svelte/transition';
  import { Brain } from 'phosphor-svelte';

  let { content = '', isStreaming = false, preview = '' } = $props();
  let expanded = $state(false);

  const displayPreview = $derived(
    preview || (content ? content.slice(0, 80).trim() + (content.length > 80 ? '...' : '') : 'Thinking...')
  );
</script>

<div class="mb-3 pb-3 border-b border-border/50">
  <button
    onclick={() => (expanded = !expanded)}
    class="flex items-center gap-2 text-sm text-muted-foreground hover:text-foreground transition-colors w-full text-left"
  >
    <Brain size={16} weight="duotone" class="shrink-0 {isStreaming ? 'animate-pulse text-primary' : ''}" />
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

#### Step 5.5: Handle thinking streaming in show.svelte
- [ ] Add state for tracking streaming thinking content
- [ ] Update streamingSync to handle thinking_update events

```javascript
// In show.svelte, add state for streaming thinking
let streamingThinking = $state({});

// Update streamingSync handler
streamingSync(
  (data) => {
    if (data.id) {
      const index = messages.findIndex((m) => m.id === data.id);
      if (index !== -1) {
        if (data.action === 'thinking_update') {
          // Handle thinking chunk
          streamingThinking[data.id] = (streamingThinking[data.id] || '') + (data.chunk || '');
        } else {
          // Existing content streaming logic
          // ...
        }
      }
    }
  },
  (data) => {
    // On stream end, clear streaming thinking (it's now in message.thinking)
    if (data.id && streamingThinking[data.id]) {
      delete streamingThinking[data.id];
      streamingThinking = { ...streamingThinking };  // Trigger reactivity
    }
    // ... existing end logic
  }
);
```

### Phase 6: Error Handling

#### Step 6.1: Handle missing Anthropic API key
- [ ] Show clear error when thinking is enabled but Anthropic key is missing/invalid
- [ ] Do NOT silently fall back to OpenRouter without thinking

```ruby
# In ManualAgentResponseJob and AllAgentsResponseJob

def perform(chat, agent)
  # ... existing setup ...

  # Validate API access for thinking-enabled Claude 4+ models
  if agent.thinking_enabled_and_supported? &&
     Agent.requires_anthropic_direct?(agent.model_id) &&
     !anthropic_direct_access_enabled?

    error_message = "Extended thinking requires Anthropic API access, but the API key is not configured. " \
                    "Please contact your administrator or disable thinking for this agent."

    chat.messages.create!(
      role: "assistant",
      agent: agent,
      content: error_message,
      streaming: false
    )
    return
  end

  # ... rest of perform
end
```

### Phase 7: Testing

#### Step 7.1: Unit tests for Agent model
- [ ] Test `supports_thinking?` class method
- [ ] Test `requires_anthropic_direct?` class method
- [ ] Test `thinking_enabled_and_supported?` instance method
- [ ] Test thinking_budget validations

```ruby
# test/models/agent_thinking_test.rb
class AgentThinkingTest < ActiveSupport::TestCase
  test "supports_thinking? returns true for capable models" do
    assert Agent.supports_thinking?("anthropic/claude-opus-4.5")
    assert Agent.supports_thinking?("openai/gpt-5")
    refute Agent.supports_thinking?("anthropic/claude-3.5-sonnet")
  end

  test "requires_anthropic_direct? returns true for Claude 4+ models" do
    assert Agent.requires_anthropic_direct?("anthropic/claude-opus-4.5")
    refute Agent.requires_anthropic_direct?("anthropic/claude-3.7-sonnet")
    refute Agent.requires_anthropic_direct?("openai/gpt-5")
  end

  test "validates thinking_budget range" do
    agent = agents(:one)
    agent.thinking_budget = 500
    refute agent.valid?

    agent.thinking_budget = 100000
    refute agent.valid?

    agent.thinking_budget = 10000
    assert agent.valid?
  end
end
```

#### Step 7.2: Integration tests for provider routing
- [ ] Test that Claude 4+ with thinking routes to Anthropic
- [ ] Test that Claude 4+ without thinking routes to OpenRouter
- [ ] Test that other models route to OpenRouter

#### Step 7.3: Frontend component tests
- [ ] Test ThinkingBlock renders collapsed by default
- [ ] Test ThinkingBlock expands on click
- [ ] Test streaming thinking display

## Code Snippets Summary

### Key Files to Modify

| File | Changes |
|------|---------|
| `db/migrate/*_add_thinking_to_messages.rb` | New migration |
| `db/migrate/*_add_thinking_settings_to_agents.rb` | New migration |
| `app/models/message.rb` | Add `thinking` attribute, `stream_thinking` method |
| `app/models/agent.rb` | Add thinking settings, model capability checks |
| `app/jobs/concerns/selects_llm_provider.rb` | Add Anthropic routing logic |
| `app/jobs/concerns/streams_ai_response.rb` | Add thinking streaming support |
| `app/jobs/manual_agent_response_job.rb` | Configure thinking, handle chunks |
| `app/jobs/all_agents_response_job.rb` | Same as ManualAgentResponseJob |
| `app/controllers/agents_controller.rb` | Permit thinking params |
| `app/frontend/pages/agents/edit.svelte` | Add thinking UI |
| `app/frontend/pages/chats/show.svelte` | Display thinking in messages |
| `app/frontend/lib/components/chat/ThinkingBlock.svelte` | New component |

### New Files

| File | Purpose |
|------|---------|
| `app/frontend/lib/components/chat/ThinkingBlock.svelte` | Collapsible thinking display |
| `test/models/agent_thinking_test.rb` | Agent thinking tests |
| `test/jobs/thinking_integration_test.rb` | Integration tests |

## Dependencies

No new external dependencies required. The implementation uses:
- RubyLLM's existing `with_params` method for Anthropic parameters
- Existing streaming infrastructure via ActionCable

## Potential Edge Cases

1. **Model switching**: If user enables thinking, then switches to a non-thinking model, the toggle should remain but be inactive. The `thinking_enabled_and_supported?` method handles this.

2. **API key validation**: Check Anthropic key format before attempting API call to provide better error messages.

3. **Very long thinking**: Consider truncating stored thinking content if it exceeds a reasonable limit (e.g., 100KB).

4. **Tool calls with thinking**: Per requirements, this is out of scope for initial implementation. Thinking should work alongside tool calls but only text responses need to capture thinking.

5. **Forked conversations**: When forking, thinking content should be copied along with message content.

## Migration Safety

Both migrations are additive (adding new columns) and are safe to run without affecting existing data:
- `thinking` column defaults to NULL
- `thinking_enabled` defaults to false
- `thinking_budget` defaults to 10000

No data migration is needed.
