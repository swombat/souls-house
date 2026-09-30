# Group Chat Feature - Final Implementation Specification

**Plan ID:** 251226-01c
**Status:** Ready for Implementation
**Revision:** Final - DHH-approved with polish refinements

## Summary

Extend chats with group functionality via a `manual_responses` boolean flag. When enabled, AI responses require explicit user trigger rather than auto-responding. Messages track agent attribution. A shared `StreamsAiResponse` concern eliminates streaming code duplication.

**Total new code: ~300 lines**

---

## 1. Database Migration

**File:** `db/migrate/[timestamp]_add_group_chat_support.rb`

```ruby
class AddGroupChatSupport < ActiveRecord::Migration[8.0]
  def change
    add_column :chats, :manual_responses, :boolean, default: false, null: false
    add_index :chats, :manual_responses

    add_reference :messages, :agent, foreign_key: true, null: true

    create_table :chat_agents do |t|
      t.references :chat, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.datetime :created_at, null: false
    end

    add_index :chat_agents, [:chat_id, :agent_id], unique: true
  end
end
```

---

## 2. Models

### 2.1 ChatAgent Join Model

**File:** `/Users/danieltenner/dev/helix_kit/app/models/chat_agent.rb`

```ruby
class ChatAgent < ApplicationRecord
  belongs_to :chat
  belongs_to :agent

  validates :agent_id, uniqueness: { scope: :chat_id }
end
```

### 2.2 Chat Model Extensions

**File:** `/Users/danieltenner/dev/helix_kit/app/models/chat.rb`

Add after `belongs_to :account`:

```ruby
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
  [system_message_for(agent)] + messages_context_for(agent)
end

private

def system_message_for(agent)
  content = agent.system_prompt.presence || "You are #{agent.name}."
  content += "\n\nYou are participating in a group conversation."
  content += " Other participants: #{participant_description(agent)}."
  { role: "system", content: content }
end

def messages_context_for(agent)
  messages.includes(:user, :agent).order(:created_at).map do |msg|
    format_message_for_context(msg, agent)
  end
end

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
    name = message.user&.full_name.presence || message.user&.email_address&.split("@")&.first || "User"
    { role: "user", content: "[#{name}]: #{message.content}" }
  end
end
```

Update `create_with_message!` method:

```ruby
def self.create_with_message!(attributes, message_content: nil, user: nil, files: nil, agent_ids: nil)
  transaction do
    chat = create!(attributes)

    chat.agent_ids = agent_ids if agent_ids.present?

    if message_content.present? || (files.present? && files.any?)
      message = chat.messages.create!({
        content: message_content || "",
        role: "user",
        user: user,
        skip_content_validation: message_content.blank? && files.present? && files.any?
      })
      message.attachments.attach(files) if files.present? && files.any?

      AiResponseJob.perform_later(chat) unless chat.manual_responses?
    end
    chat
  end
end
```

### 2.3 Message Model Extensions

**File:** `/Users/danieltenner/dev/helix_kit/app/models/message.rb`

Add after `belongs_to :user, optional: true`:

```ruby
belongs_to :agent, optional: true
```

Update `json_attributes` line to include `:author_name, :author_type`:

```ruby
json_attributes :role, :content, :user_name, :user_avatar_url, :completed,
                :created_at_formatted, :created_at_hour, :streaming, :files_json,
                :content_html, :tools_used, :tool_status, :author_name, :author_type
```

Add these methods:

```ruby
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

---

## 3. Jobs

### 3.1 StreamsAiResponse Concern

**File:** `/Users/danieltenner/dev/helix_kit/app/jobs/concerns/streams_ai_response.rb`

```ruby
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

### 3.2 Update AiResponseJob

**File:** `/Users/danieltenner/dev/helix_kit/app/jobs/ai_response_job.rb`

```ruby
class AiResponseJob < ApplicationJob
  include StreamsAiResponse

  def perform(chat)
    raise ArgumentError, "Expected a Chat object" unless chat.is_a?(Chat)

    @chat = chat
    @ai_message = nil
    setup_streaming_state

    chat.available_tools.each { |tool| chat = chat.with_tool(tool) }

    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
      @ai_message.update!(streaming: true) if @ai_message
    end

    chat.on_tool_call { |tc| handle_tool_call(tc) }
    chat.on_end_message { |msg| finalize_message!(msg) }

    chat.complete do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end
  rescue RubyLLM::ModelNotFoundError => e
    Rails.logger.error "Model not found: #{e.message}"
    RubyLLM.models.refresh!
    retry_job
  ensure
    cleanup_streaming
  end
end
```

### 3.3 ManualAgentResponseJob

**File:** `/Users/danieltenner/dev/helix_kit/app/jobs/manual_agent_response_job.rb`

```ruby
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

    llm.ask(context) do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end
  rescue RubyLLM::ModelNotFoundError => e
    Rails.logger.error "Model not found: #{e.message}"
    RubyLLM.models.refresh!
    retry_job
  ensure
    cleanup_streaming
  end
end
```

---

## 4. Routes

**File:** `/Users/danieltenner/dev/helix_kit/config/routes.rb`

Update the chats resource block (using member action per DHH's suggestion):

```ruby
resources :chats do
  member do
    post "trigger_agent/:agent_id", action: :trigger_agent, as: :trigger_agent
  end
  resources :messages, only: :create
end
```

This gives us: `trigger_agent_account_chat_path(account_id, chat_id, agent_id)`

---

## 5. Controllers

### 5.1 ChatsController Updates

**File:** `/Users/danieltenner/dev/helix_kit/app/controllers/chats_controller.rb`

Update `create` action:

```ruby
def create
  chat_attrs = chat_params
  chat_attrs[:manual_responses] = true if params[:agent_ids].present?

  @chat = current_account.chats.create_with_message!(
    chat_attrs,
    message_content: params[:message],
    user: Current.user,
    files: params[:files],
    agent_ids: params[:agent_ids]
  )
  audit("create_chat", @chat, **chat_params.to_h)
  redirect_to account_chat_path(current_account, @chat)
end
```

Update `show` action:

```ruby
def show
  @chats = current_account.chats.latest
  @messages = @chat.messages.includes(:user, :agent).with_attached_attachments.sorted

  render inertia: "chats/show", props: {
    chat: @chat.as_json,
    chats: @chats.as_json,
    messages: @messages.all.collect(&:as_json),
    account: current_account.as_json,
    models: available_models,
    agents: @chat.group_chat? ? @chat.agents.as_json : [],
    file_upload_config: file_upload_config
  }
end
```

Add `trigger_agent` action:

```ruby
def trigger_agent
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

Update `chat_params`:

```ruby
def chat_params
  params.fetch(:chat, {}).permit(:model_id, :web_access, :manual_responses)
end
```

Extract `file_upload_config` helper:

```ruby
def file_upload_config
  {
    acceptable_types: Message::ACCEPTABLE_FILE_TYPES.values.flatten,
    max_size: Message::MAX_FILE_SIZE
  }
end
```

### 5.2 MessagesController Update

**File:** `/Users/danieltenner/dev/helix_kit/app/controllers/messages_controller.rb`

Update `create` action to skip auto-response for group chats:

```ruby
def create
  @message = @chat.messages.build(
    message_params.merge(user: Current.user, role: "user")
  )
  @message.attachments.attach(params[:files]) if params[:files].present?

  if @message.save
    audit("create_message", @message, **message_params.to_h)
    AiResponseJob.perform_later(@chat) unless @chat.manual_responses?

    respond_to do |format|
      format.html { redirect_to account_chat_path(@chat.account, @chat) }
      format.json { render json: @message, status: :created }
    end
  else
    # ... existing error handling
  end
end
```

---

## 6. Frontend

### 6.1 AgentTriggerBar Component

**File:** `/Users/danieltenner/dev/helix_kit/app/frontend/lib/components/chat/AgentTriggerBar.svelte`

```svelte
<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Robot, Spinner } from 'phosphor-svelte';
  import { triggerAgentAccountChatPath } from '@/routes';

  let { agents = [], accountId, chatId, disabled = false } = $props();
  let triggeringAgent = $state(null);

  function triggerAgent(agent) {
    if (triggeringAgent) return;
    triggeringAgent = agent.id;

    router.post(triggerAgentAccountChatPath(accountId, chatId, agent.id), {}, {
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

### 6.2 Update chats/show.svelte

**File:** `/Users/danieltenner/dev/helix_kit/app/frontend/pages/chats/show.svelte`

Add import:

```svelte
import AgentTriggerBar from '$lib/components/chat/AgentTriggerBar.svelte';
```

Add after messages container, before input area:

```svelte
{#if chat?.manual_responses && agents?.length > 0}
  <AgentTriggerBar {agents} accountId={account.id} chatId={chat.id} />
{/if}
```

### 6.3 Regenerate JS Routes

```bash
bin/rails js_from_routes:generate
```

---

## 7. Implementation Checklist

### Database
- [ ] Create migration `rails g migration AddGroupChatSupport`
- [ ] Run migration `rails db:migrate`

### Models
- [ ] Create `/app/models/chat_agent.rb`
- [ ] Add associations and group chat methods to `Chat`
- [ ] Update `Chat.create_with_message!` for agent_ids
- [ ] Add agent association and author methods to `Message`

### Jobs
- [ ] Create `/app/jobs/concerns/streams_ai_response.rb`
- [ ] Refactor `AiResponseJob` to use concern
- [ ] Create `/app/jobs/manual_agent_response_job.rb`

### Routes & Controllers
- [ ] Update routes with `trigger_agent` member action
- [ ] Update `ChatsController#create` and `#show`
- [ ] Add `ChatsController#trigger_agent`
- [ ] Update `MessagesController#create` for manual_responses

### Frontend
- [ ] Create `AgentTriggerBar.svelte`
- [ ] Update `chats/show.svelte`
- [ ] Run `bin/rails js_from_routes:generate`

### Testing
- [ ] Test `manual_responses` flag behavior
- [ ] Test agent attribution on messages
- [ ] Test `trigger_agent` endpoint
- [ ] Test context building for agents
- [ ] Test that group chats require at least one agent

---

## 8. Testing Examples

```ruby
# test/models/chat_test.rb
class ChatTest < ActiveSupport::TestCase
  test "group_chat? returns true when manual_responses is true" do
    chat = chats(:one)
    chat.update!(manual_responses: true)
    assert chat.group_chat?
  end

  test "trigger_agent_response! raises for non-participating agent" do
    chat = chats(:one)
    chat.update!(manual_responses: true)
    other_agent = agents(:two)

    assert_raises(ArgumentError) { chat.trigger_agent_response!(other_agent) }
  end

  test "build_context_for_agent formats messages correctly" do
    chat = chats(:group_chat)
    agent = chat.agents.first
    context = chat.build_context_for_agent(agent)

    assert_equal "system", context.first[:role]
    assert context.first[:content].include?("group conversation")
  end
end

# test/controllers/chats_controller_test.rb
class ChatsControllerTest < ActionDispatch::IntegrationTest
  test "trigger_agent enqueues job for participating agent" do
    chat = chats(:group_chat)
    agent = chat.agents.first

    assert_enqueued_with(job: ManualAgentResponseJob) do
      post trigger_agent_account_chat_path(chat.account, chat, agent)
    end
  end
end
```

---

## Code Summary

| Component | Lines | File |
|-----------|-------|------|
| Migration | 15 | `db/migrate/*_add_group_chat_support.rb` |
| ChatAgent model | 7 | `app/models/chat_agent.rb` |
| Chat model additions | 55 | `app/models/chat.rb` |
| Message model additions | 20 | `app/models/message.rb` |
| StreamsAiResponse concern | 60 | `app/jobs/concerns/streams_ai_response.rb` |
| AiResponseJob refactor | 30 | `app/jobs/ai_response_job.rb` |
| ManualAgentResponseJob | 45 | `app/jobs/manual_agent_response_job.rb` |
| Routes | 4 | `config/routes.rb` |
| ChatsController additions | 25 | `app/controllers/chats_controller.rb` |
| MessagesController update | 2 | `app/controllers/messages_controller.rb` |
| AgentTriggerBar.svelte | 40 | `app/frontend/lib/components/chat/AgentTriggerBar.svelte` |
| show.svelte update | 5 | `app/frontend/pages/chats/show.svelte` |
| **Total** | **~308** | |
