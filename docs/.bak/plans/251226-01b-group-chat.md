# Group Chat Feature - Implementation Specification (Revised)

**Plan ID:** 251226-01b
**Created:** 2025-12-26
**Status:** Ready for Implementation
**Revision:** Second iteration - DHH-approved lean approach

## Executive Summary

Add group chat functionality by **extending existing infrastructure** rather than creating parallel hierarchies. The key insight: the only behavioral difference between a regular chat and a group chat is "who triggers AI responses" (automatic vs manual) and "which agents participate." This can be achieved with:

- 2 new columns on existing tables
- 1 small join table
- ~25 lines of controller extensions
- ~50 lines for agent trigger buttons
- Subclassing existing job logic

**Target: ~150 lines of new code, not 1,000+.**

## Architecture Overview

### What Changes

| Component | Change |
|-----------|--------|
| `chats` table | Add `manual_responses` boolean (default: false) |
| `messages` table | Add `agent_id` for attribution |
| New `chat_agents` table | Simple join table linking chats to participating agents |
| `Chat` model | Add `chat_agents` association, `trigger_agent_response!` method |
| `Message` model | Add `agent` association, `author_name`/`author_type` methods |
| `ChatsController` | Extend `create` and `show` to handle agents |
| `MessagesController` | Add `trigger_agent` action |
| `AiResponseJob` | Extract base class, subclass for manual trigger |
| Frontend | Add AgentTriggerBar component (~50 lines) |

### What Stays the Same

Everything else. Same `Chat` model, same `Message` model, same streaming logic, same broadcasting, same concerns. We reuse 100% of the existing chat infrastructure.

## Database Design

### Migration

```ruby
# db/migrate/[timestamp]_add_group_chat_support.rb
class AddGroupChatSupport < ActiveRecord::Migration[8.0]
  def change
    # Chat can have manual AI responses (group chat mode)
    add_column :chats, :manual_responses, :boolean, default: false, null: false
    add_index :chats, :manual_responses

    # Messages can be attributed to an agent (for group chats)
    add_reference :messages, :agent, foreign_key: true, null: true

    # Join table: which agents participate in which chats
    create_table :chat_agents do |t|
      t.references :chat, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.datetime :created_at, null: false
    end

    add_index :chat_agents, [:chat_id, :agent_id], unique: true
  end
end
```

**Total: ~20 lines**

## Model Changes

### Chat Model Extensions

```ruby
# app/models/chat.rb - ADD these lines (do not replace existing code)

has_many :chat_agents, dependent: :destroy
has_many :agents, through: :chat_agents

validates :agents, length: { minimum: 1, message: "must include at least one agent" }, if: :manual_responses?

def group_chat?
  manual_responses?
end

def trigger_agent_response!(agent)
  raise ArgumentError, "Agent not in this conversation" unless agents.include?(agent)
  raise ArgumentError, "This chat does not support manual responses" unless manual_responses?

  ManualAgentResponseJob.perform_later(self, agent)
end

def build_context_for_agent(agent)
  system_content = agent.system_prompt.presence || "You are #{agent.name}."
  system_content += "\n\nYou are participating in a group conversation."
  system_content += " Other participants: #{participant_description(agent)}."

  context = [{ role: "system", content: system_content }]

  messages.includes(:user, :agent).order(:created_at).each do |msg|
    context << format_message_for_context(msg, agent)
  end

  context
end

private

def participant_description(current_agent)
  humans = messages.where.not(user_id: nil).joins(:user)
                   .distinct.pluck("users.email_address")
                   .map { |email| email.split("@").first }
  other_agents = agents.where.not(id: current_agent.id).pluck(:name)

  parts = []
  parts << "Humans: #{humans.join(', ')}" if humans.any?
  parts << "AI Agents: #{other_agents.join(', ')}" if other_agents.any?
  parts.join(". ")
end

def format_message_for_context(message, current_agent)
  if message.agent_id == current_agent.id
    { role: "assistant", content: message.content }
  elsif message.agent_id.present?
    { role: "user", content: "[#{message.agent.name}]: #{message.content}" }
  else
    name = message.user&.full_name || message.user&.email_address&.split("@")&.first || "User"
    { role: "user", content: "[#{name}]: #{message.content}" }
  end
end
```

**Total: ~45 lines added to existing model**

### ChatAgent Join Model

```ruby
# app/models/chat_agent.rb
class ChatAgent < ApplicationRecord
  belongs_to :chat
  belongs_to :agent

  validates :agent_id, uniqueness: { scope: :chat_id }
end
```

**Total: 7 lines**

### Message Model Extensions

```ruby
# app/models/message.rb - ADD these lines

belongs_to :agent, optional: true

json_attributes :author_name, :author_type  # Add to existing json_attributes line

def author_name
  if agent.present?
    agent.name
  elsif user.present?
    user.full_name.presence || user.email_address.split("@").first
  else
    "System"
  end
end

def author_type
  if agent.present?
    "agent"
  elsif user.present?
    "human"
  else
    "system"
  end
end
```

**Total: ~20 lines added to existing model**

### Account Model Extension

```ruby
# app/models/account.rb - ADD this line after has_many :agents

has_many :chat_agents, through: :chats
```

**Total: 1 line**

## Job Changes

### Extract Base Streaming Logic

The existing `AiResponseJob` contains streaming logic that we need for both automatic and manual responses. We'll extract a concern:

```ruby
# app/jobs/concerns/streams_ai_response.rb
module StreamsAiResponse
  extend ActiveSupport::Concern

  STREAM_DEBOUNCE_INTERVAL = 0.2.seconds

  private

  def setup_streaming_state
    @stream_buffer = +""
    @last_stream_flush_at = nil
    @tools_used = []
  end

  def finalize_message!(ruby_llm_message)
    return unless @ai_message

    flush_stream_buffer(force: true)

    @ai_message.update!({
      content: extract_message_content(ruby_llm_message.content),
      model_id_string: ruby_llm_message.model_id,
      input_tokens: ruby_llm_message.input_tokens,
      output_tokens: ruby_llm_message.output_tokens,
      tools_used: @tools_used.uniq,
      streaming: false
    })
  end

  def extract_message_content(content)
    case content
    when RubyLLM::Content then content.text
    when Hash, Array then content.to_json
    else content
    end
  end

  def enqueue_stream_chunk(chunk_content)
    @stream_buffer << chunk_content.to_s
    flush_stream_buffer if stream_flush_due?
  end

  def flush_stream_buffer(force: false)
    return if @stream_buffer.blank?
    return unless @ai_message
    return unless force || stream_flush_due?

    chunk = @stream_buffer
    @stream_buffer = +""
    @last_stream_flush_at = Time.current
    @ai_message.stream_content(chunk)
  end

  def stream_flush_due?
    return true unless @last_stream_flush_at
    Time.current - @last_stream_flush_at >= STREAM_DEBOUNCE_INTERVAL
  end

  def handle_tool_call(tool_call)
    url = tool_call.arguments[:url] || tool_call.arguments["url"]
    @tools_used << (url || tool_call.name.to_s)

    @ai_message&.broadcast_tool_call(
      tool_name: tool_call.name.to_s,
      tool_args: tool_call.arguments
    )
  end

  def cleanup_streaming
    flush_stream_buffer(force: true)
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end
end
```

**Total: ~65 lines**

### Update AiResponseJob

```ruby
# app/jobs/ai_response_job.rb - REPLACE with:
class AiResponseJob < ApplicationJob
  include StreamsAiResponse

  def perform(chat)
    raise ArgumentError, "Expected a Chat object" unless chat.is_a?(Chat)

    @chat = chat
    @ai_message = nil
    setup_streaming_state

    chat.available_tools.each { |tool| chat = chat.with_tool(tool) }

    chat.on_new_message { @ai_message = chat.messages.order(:created_at).last; @ai_message.update!(streaming: true) if @ai_message }
    chat.on_tool_call { |tc| handle_tool_call(tc) }
    chat.on_end_message { |msg| finalize_message!(msg) }

    chat.complete { |chunk| enqueue_stream_chunk(chunk.content) if chunk.content && @ai_message }
  rescue RubyLLM::ModelNotFoundError => e
    Rails.logger.error "Model not found: #{e.message}"
    RubyLLM.models.refresh!
    retry_job
  ensure
    cleanup_streaming
  end
end
```

### Create ManualAgentResponseJob

```ruby
# app/jobs/manual_agent_response_job.rb
class ManualAgentResponseJob < ApplicationJob
  include StreamsAiResponse

  def perform(chat, agent)
    @chat = chat
    @agent = agent
    @ai_message = nil
    setup_streaming_state

    context = chat.build_context_for_agent(agent)

    llm = RubyLLM.chat(
      model: agent.model_id,
      provider: :openrouter,
      assume_model_exists: true
    )

    agent.tools.each { |tool| llm = llm.with_tool(tool) }

    llm.on_new_message do
      @ai_message = chat.messages.create!(
        role: "assistant",
        agent: agent,
        content: "",
        streaming: true
      )
    end

    llm.on_tool_call { |tc| handle_tool_call(tc) }
    llm.on_end_message { |msg| finalize_message!(msg) }

    llm.ask(context) { |chunk| enqueue_stream_chunk(chunk.content) if chunk.content && @ai_message }
  rescue RubyLLM::ModelNotFoundError => e
    Rails.logger.error "Model not found: #{e.message}"
    RubyLLM.models.refresh!
    retry_job
  ensure
    cleanup_streaming
  end
end
```

**Total: ~40 lines**

## Controller Changes

### Extend ChatsController

```ruby
# app/controllers/chats_controller.rb - MODIFY create action and add private methods

def create
  chat_attrs = chat_params

  # Handle group chat creation
  if params[:agent_ids].present?
    chat_attrs[:manual_responses] = true
  end

  @chat = current_account.chats.create_with_message!(
    chat_attrs,
    message_content: params[:message],
    user: Current.user,
    files: params[:files],
    agent_ids: params[:agent_ids]  # Pass to create_with_message!
  )
  audit("create_chat", @chat, **chat_params.to_h)
  redirect_to account_chat_path(current_account, @chat)
end

def show
  @chats = current_account.chats.latest
  @messages = @chat.messages.includes(:user, :agent).with_attached_attachments.sorted

  render inertia: "chats/show", props: {
    chat: @chat.as_json,
    chats: @chats.as_json,
    messages: @messages.all.collect(&:as_json),
    account: current_account.as_json,
    models: available_models,
    agents: @chat.manual_responses? ? @chat.agents.as_json : [],  # ADD this line
    file_upload_config: file_upload_config
  }
end

private

def chat_params
  params.fetch(:chat, {}).permit(:model_id, :web_access, :manual_responses)  # ADD :manual_responses
end
```

### Extend Chat.create_with_message!

```ruby
# app/models/chat.rb - MODIFY create_with_message!

def self.create_with_message!(attributes, message_content: nil, user: nil, files: nil, agent_ids: nil)
  transaction do
    chat = create!(attributes)

    # Attach agents if provided (for group chats)
    if agent_ids.present?
      chat.agent_ids = agent_ids
    end

    if message_content.present? || (files.present? && files.any?)
      message = chat.messages.create!({
        content: message_content || "",
        role: "user",
        user: user,
        skip_content_validation: message_content.blank? && files.present? && files.any?
      })
      message.attachments.attach(files) if files.present? && files.any?

      # Only auto-trigger AI if not manual_responses mode
      AiResponseJob.perform_later(chat) unless chat.manual_responses?
    end
    chat
  end
end
```

### Extend MessagesController

```ruby
# app/controllers/messages_controller.rb - ADD trigger_agent action

def trigger_agent
  @chat = current_account.chats.find(params[:chat_id])
  @agent = @chat.agents.find(params[:agent_id])

  @chat.trigger_agent_response!(@agent)

  respond_to do |format|
    format.html { redirect_to account_chat_path(current_account, @chat) }
    format.json { head :ok }
  end
rescue ArgumentError => e
  respond_to do |format|
    format.html { redirect_back_or_to account_chat_path(current_account, @chat), alert: e.message }
    format.json { render json: { error: e.message }, status: :unprocessable_entity }
  end
end
```

**Controller changes total: ~30 lines**

## Routes

```ruby
# config/routes.rb - MODIFY existing resources

resources :chats do
  resources :messages, only: :create do
    collection do
      post "trigger/:agent_id", action: :trigger_agent, as: :trigger_agent
    end
  end
end
```

**Total: 4 lines added**

## Frontend Changes

### AgentTriggerBar Component

```svelte
<!-- app/frontend/lib/components/chat/AgentTriggerBar.svelte -->
<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Robot, Spinner } from 'phosphor-svelte';
  import { triggerAgentAccountChatMessagesPath } from '@/routes';

  let { agents = [], accountId, chatId, disabled = false } = $props();
  let triggeringAgent = $state(null);

  function triggerAgent(agent) {
    if (triggeringAgent) return;
    triggeringAgent = agent.id;

    router.post(triggerAgentAccountChatMessagesPath(accountId, chatId, agent.id), {}, {
      onFinish: () => { triggeringAgent = null; },
      onError: () => { triggeringAgent = null; }
    });
  }
</script>

{#if agents.length > 0}
  <div class="border-t border-border px-6 py-3 bg-muted/20">
    <div class="flex items-center gap-2 flex-wrap">
      <span class="text-xs text-muted-foreground mr-2">Ask agent:</span>
      {#each agents as agent (agent.id)}
        <Button
          variant="outline"
          size="sm"
          onclick={() => triggerAgent(agent)}
          disabled={disabled || triggeringAgent !== null}
          class="gap-2">
          {#if triggeringAgent === agent.id}
            <Spinner size={14} class="animate-spin" />
          {:else}
            <Robot size={14} weight="duotone" />
          {/if}
          {agent.name}
        </Button>
      {/each}
    </div>
  </div>
{/if}
```

**Total: ~45 lines**

### Update chats/show.svelte

Add 3 lines to import and use the component:

```svelte
<!-- In script section -->
import AgentTriggerBar from '$lib/components/chat/AgentTriggerBar.svelte';

<!-- After messages container, before input -->
{#if chat?.manual_responses && agents?.length > 0}
  <AgentTriggerBar {agents} accountId={account.id} chatId={chat.id} />
{/if}
```

### Update chats/new.svelte

For creating group chats, we need agent selection. This can be a simple extension:

```svelte
<!-- Add to existing new.svelte, in the settings area -->
{#if $page.props.site_settings?.allow_agents && availableAgents?.length > 0}
  <div class="mb-4">
    <label class="flex items-center gap-2 cursor-pointer mb-2">
      <input type="checkbox" bind:checked={isGroupChat} class="..." />
      <span>Group Chat (manual AI responses)</span>
    </label>

    {#if isGroupChat}
      <div class="space-y-2 ml-6">
        <p class="text-sm text-muted-foreground">Select participating agents:</p>
        {#each availableAgents as agent}
          <label class="flex items-center gap-2">
            <input type="checkbox"
                   checked={selectedAgentIds.includes(agent.id)}
                   onchange={() => toggleAgent(agent.id)} />
            {agent.name}
          </label>
        {/each}
      </div>
    {/if}
  </div>
{/if}
```

Then modify the form submission to include `agent_ids[]` when `isGroupChat` is true.

**Frontend additions total: ~60 lines**

### Update Navbar

```svelte
<!-- app/frontend/lib/components/navigation/navbar.svelte -->
<!-- No changes needed - group chats appear in the regular Chats list -->
```

Group chats will appear in the normal chat list with a visual indicator (the agents badge in the sidebar).

## Implementation Checklist

### Database
- [ ] Create migration adding `manual_responses` to chats, `agent_id` to messages, and `chat_agents` table
- [ ] Run migration

### Models
- [ ] Create `ChatAgent` join model (7 lines)
- [ ] Add group chat methods to `Chat` model (~45 lines)
- [ ] Add author attribution to `Message` model (~20 lines)
- [ ] Add `chat_agents` association to `Account` (1 line)

### Jobs
- [ ] Extract `StreamsAiResponse` concern (~65 lines)
- [ ] Update `AiResponseJob` to use concern
- [ ] Create `ManualAgentResponseJob` (~40 lines)

### Controllers
- [ ] Extend `ChatsController#create` for agent selection
- [ ] Extend `ChatsController#show` to pass agents
- [ ] Add `MessagesController#trigger_agent` action
- [ ] Update routes

### Frontend
- [ ] Create `AgentTriggerBar.svelte` component (~45 lines)
- [ ] Update `chats/show.svelte` to show trigger bar
- [ ] Update `chats/new.svelte` for agent selection
- [ ] Regenerate js-routes

### Testing
- [ ] Test manual_responses flag behavior
- [ ] Test agent attribution on messages
- [ ] Test trigger_agent endpoint
- [ ] Test context building for agents

## Code Summary

| Component | Lines | Purpose |
|-----------|-------|---------|
| Migration | ~20 | Add columns and join table |
| ChatAgent model | 7 | Join model |
| Chat model additions | ~45 | Group chat methods |
| Message model additions | ~20 | Author attribution |
| StreamsAiResponse concern | ~65 | Shared streaming logic |
| ManualAgentResponseJob | ~40 | Manual trigger job |
| Controller changes | ~30 | Extend existing controllers |
| AgentTriggerBar.svelte | ~45 | Trigger buttons |
| chats/show.svelte changes | ~5 | Use trigger bar |
| chats/new.svelte changes | ~25 | Agent selection |
| **Total** | **~302** | Complete feature |

## Why This Approach is Better

1. **No parallel hierarchies** - Group chats ARE chats, just with different behavior
2. **Reuses 100% of existing streaming/broadcasting** - No code duplication
3. **Single source of truth** - One `messages` table, one `chats` table
4. **Minimal migration risk** - Additive changes only
5. **Future flexibility preserved** - Can still evolve without refactoring
6. **Obvious code paths** - `manual_responses?` predicate makes behavior clear

## What DHH Would Say

"This is how you extend a Rails app. You don't create `GroupChat` when `Chat` already exists. You add a boolean. You don't create `GroupMessage` when `Message` already exists. You add a foreign key. The framework gives you associations and concerns for exactly this purpose. Use them."
