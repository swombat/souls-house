# Group Chat Feature - Implementation Specification

**Plan ID:** 251226-01a
**Created:** 2025-12-26
**Status:** Ready for Implementation
**Revision:** First iteration

## Executive Summary

Add a Group Chat feature enabling humans and AI agents to collaborate in shared conversations. Unlike standard chats where AI responds automatically, group chats allow users to manually trigger responses from any participating agent. This creates a collaborative workspace where multiple AI personalities can contribute to discussions alongside human participants.

## Architecture Overview

### Core Differences from Standard Chat

| Aspect | Standard Chat | Group Chat |
|--------|--------------|------------|
| AI Response | Automatic after user message | Manual trigger via agent buttons |
| Participants | 1 user + 1 AI model | N users + N agents |
| Model Selection | Per chat | Per agent (pre-configured) |
| Message Attribution | User/Assistant roles | Named participants (human + agent names) |
| Tools | Chat-level web access toggle | Per-agent tool configuration |

### New Components

1. **GroupChat Model** - Account-scoped conversation with many agents
2. **GroupChatParticipant Join Model** - Links agents to group chats
3. **GroupMessage Model** - Messages with agent attribution (or reuse Message with agent_id)
4. **GroupChatsController** - CRUD + agent response triggering
5. **GroupMessagesController** - Message creation + agent response endpoint
6. **GroupAgentResponseJob** - Background job for agent responses
7. **Svelte Pages** - New/Show pages with agent selection and trigger buttons

### Rails Philosophy

- **Fat Models, Skinny Controllers** - Response triggering logic in GroupChat model
- **Association-Based Authorization** - `current_account.group_chats.find(id)`
- **Concerns for Shared Behavior** - Reuse Broadcastable, JsonAttributes, etc.
- **No Service Objects** - Keep logic in models and jobs
- **Convention Over Configuration** - RESTful resources, standard patterns

## Database Design

### Option A: Separate Tables (Recommended)

Creates dedicated tables for group chats, keeping standard chats simple and avoiding schema pollution.

```ruby
# group_chats table
- id: bigint (primary key)
- account_id: bigint (foreign key, required)
- title: string (optional, auto-generated like Chat)
- created_at, updated_at: timestamps

# group_chat_participants table (join table for agents)
- id: bigint (primary key)
- group_chat_id: bigint (foreign key, required)
- agent_id: bigint (foreign key, required)
- created_at: timestamp

# group_messages table
- id: bigint (primary key)
- group_chat_id: bigint (foreign key, required)
- user_id: bigint (foreign key, optional - for human messages)
- agent_id: bigint (foreign key, optional - for agent messages)
- content: text
- role: string (user/assistant/system/tool)
- streaming: boolean (default: false)
- tool_status: string (nullable)
- tools_used: text[] (array)
- ai_model_id: bigint (foreign key, optional)
- model_id_string: string (for tracking which model was used)
- input_tokens: integer (optional)
- output_tokens: integer (optional)
- created_at, updated_at: timestamps
```

### Why Separate Tables?

1. **Clean Separation** - Group chats have different semantics (no auto-response, multiple agents)
2. **Simpler Queries** - No polymorphic associations or conditionals
3. **Future Flexibility** - Can evolve independently (e.g., add scheduling, tagging)
4. **No Migration Risk** - Existing chat functionality untouched
5. **Clear Code** - `GroupChat` vs `Chat` immediately communicates intent

## Implementation Steps

### Step 1: Database Migration

- [ ] Create group_chats, group_chat_participants, and group_messages tables

```ruby
# db/migrate/[timestamp]_create_group_chats.rb
class CreateGroupChats < ActiveRecord::Migration[8.0]
  def change
    create_table :group_chats do |t|
      t.references :account, null: false, foreign_key: true
      t.string :title

      t.timestamps
    end

    add_index :group_chats, [:account_id, :created_at]

    create_table :group_chat_participants do |t|
      t.references :group_chat, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true

      t.datetime :created_at, null: false
    end

    add_index :group_chat_participants, [:group_chat_id, :agent_id], unique: true

    create_table :group_messages do |t|
      t.references :group_chat, null: false, foreign_key: true
      t.references :user, null: true, foreign_key: true
      t.references :agent, null: true, foreign_key: true
      t.references :ai_model, null: true, foreign_key: true

      t.text :content
      t.string :role, null: false
      t.boolean :streaming, default: false, null: false
      t.string :tool_status
      t.text :tools_used, array: true, default: []
      t.string :model_id_string
      t.integer :input_tokens
      t.integer :output_tokens
      t.bigint :tool_call_id

      t.timestamps
    end

    add_index :group_messages, [:group_chat_id, :created_at]
    add_index :group_messages, :streaming
    add_index :group_messages, :tools_used, using: :gin

    create_table :group_tool_calls do |t|
      t.references :group_message, null: false, foreign_key: true
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.jsonb :arguments, default: {}

      t.timestamps
    end

    add_index :group_tool_calls, :tool_call_id
  end
end
```

### Step 2: Create GroupChat Model

- [ ] Implement GroupChat model with participant management

```ruby
# app/models/group_chat.rb
class GroupChat < ApplicationRecord

  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include JsonAttributes

  belongs_to :account
  has_many :group_chat_participants, dependent: :destroy
  has_many :agents, through: :group_chat_participants
  has_many :group_messages, dependent: :destroy

  validates :agents, length: { minimum: 1, message: "must include at least one agent" }

  broadcasts_to :account

  scope :latest, -> { order(updated_at: :desc) }

  json_attributes :title_or_default, :updated_at_formatted, :updated_at_short,
                  :message_count, :agent_names

  after_create_commit -> { GenerateGroupTitleJob.perform_later(self) }, unless: :title?

  def self.create_with_message!(attributes, agent_ids:, message_content: nil, user: nil, files: nil)
    transaction do
      group_chat = new(attributes)
      group_chat.agent_ids = agent_ids
      group_chat.save!

      if message_content.present? || (files.present? && files.any?)
        message = group_chat.group_messages.create!({
          content: message_content || "",
          role: "user",
          user: user
        })
        message.attachments.attach(files) if files.present? && files.any?
      end

      group_chat
    end
  end

  def title_or_default
    title.presence || agent_names.join(", ").truncate(50).presence || "New Group Chat"
  end

  def agent_names
    agents.pluck(:name)
  end

  def updated_at_formatted
    updated_at.strftime("%b %d at %l:%M %p")
  end

  def updated_at_short
    updated_at.strftime("%b %d")
  end

  def message_count
    group_messages.count
  end

  def trigger_agent_response!(agent)
    raise ArgumentError, "Agent not in this conversation" unless agents.include?(agent)
    GroupAgentResponseJob.perform_later(self, agent)
  end

  def build_context_for_agent(agent)
    messages_for_context = group_messages.includes(:user, :agent).order(:created_at)

    system_content = agent.system_prompt.presence || "You are #{agent.name}."
    system_content += "\n\nYou are participating in a group conversation. "
    system_content += "Other participants: #{participant_description(agent)}."

    context = [{ role: "system", content: system_content }]

    messages_for_context.each do |msg|
      context << format_message_for_context(msg, agent)
    end

    context
  end

  private

  def participant_description(current_agent)
    humans = group_messages.where.not(user_id: nil).joins(:user)
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

end
```

### Step 3: Create GroupChatParticipant Model

- [ ] Implement join model for agents in group chats

```ruby
# app/models/group_chat_participant.rb
class GroupChatParticipant < ApplicationRecord

  belongs_to :group_chat
  belongs_to :agent

  validates :agent_id, uniqueness: { scope: :group_chat_id }

end
```

### Step 4: Create GroupMessage Model

- [ ] Implement GroupMessage with attribution support

```ruby
# app/models/group_message.rb
class GroupMessage < ApplicationRecord

  include Broadcastable
  include ObfuscatesId
  include JsonAttributes
  include SyncAuthorizable

  belongs_to :group_chat, touch: true
  belongs_to :user, optional: true
  belongs_to :agent, optional: true
  belongs_to :ai_model, optional: true
  has_one :account, through: :group_chat

  has_many_attached :attachments
  has_many :group_tool_calls, dependent: :destroy

  broadcasts_to :group_chat

  validates :role, inclusion: { in: %w[user assistant system tool] }
  validates :content, presence: true, unless: -> { role.in?(%w[assistant tool]) }
  validate :must_have_author

  scope :sorted, -> { order(created_at: :asc) }

  json_attributes :role, :content, :author_name, :author_type, :author_avatar_url,
                  :completed, :created_at_formatted, :streaming, :content_html,
                  :tools_used, :tool_status, :files_json

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

  def author_avatar_url
    user&.avatar_url
  end

  def completed?
    role == "user" || (role == "assistant" && content.present?)
  end

  alias_method :completed, :completed?

  def created_at_formatted
    created_at.strftime("%l:%M %p")
  end

  def content_html
    render_markdown
  end

  def files_json
    return [] unless attachments.attached?

    attachments.map do |file|
      {
        id: file.id,
        filename: file.filename.to_s,
        content_type: file.content_type,
        byte_size: file.byte_size,
        url: Rails.application.routes.url_helpers.url_for(file)
      }
    rescue ArgumentError
      { id: file.id, filename: file.filename.to_s, url: "/files/#{file.id}" }
    end
  end

  def stream_content(chunk)
    chunk = chunk.to_s
    return if chunk.empty?

    update_columns(streaming: true, content: (content.to_s + chunk))

    broadcast_marker(
      "GroupMessage:#{to_param}",
      {
        action: "streaming_update",
        chunk: chunk,
        id: to_param
      }
    )
  end

  def stop_streaming
    update!(streaming: false, tool_status: nil) if streaming?
    broadcast_marker(
      "GroupMessage:#{to_param}",
      {
        action: "streaming_end",
        chunk: nil,
        id: to_param
      }
    )
  end

  def broadcast_tool_call(tool_name:, tool_args:)
    status = format_tool_status(tool_name, tool_args)
    update!(tool_status: status)
  end

  private

  def must_have_author
    if role == "user" && user_id.blank?
      errors.add(:base, "User messages must have a user")
    end
    if role == "assistant" && agent_id.blank?
      errors.add(:base, "Assistant messages must have an agent")
    end
  end

  def format_tool_status(tool_name, tool_args)
    case tool_name
    when "WebFetchTool", "web_fetch"
      url = tool_args[:url] || tool_args["url"]
      "Fetching #{truncate_url(url)}"
    when "WebSearchTool", "web_search"
      query = tool_args[:query] || tool_args["query"]
      "Searching for \"#{query}\""
    else
      "Using #{tool_name.to_s.underscore.humanize.downcase}"
    end
  end

  def truncate_url(url)
    return url if url.nil? || url.length <= 50
    "#{url[0..47]}..."
  end

  def render_markdown
    renderer = Redcarpet::Markdown.new(
      Redcarpet::Render::HTML.new(
        filter_html: true,
        safe_links_only: true,
        hard_wrap: true
      ),
      autolink: true,
      fenced_code_blocks: true,
      tables: true,
      strikethrough: true
    )
    renderer.render(content || "").html_safe
  end

end
```

### Step 5: Create GroupToolCall Model

- [ ] Implement tool call tracking for group messages

```ruby
# app/models/group_tool_call.rb
class GroupToolCall < ApplicationRecord

  belongs_to :group_message

  validates :tool_call_id, presence: true
  validates :name, presence: true

end
```

### Step 6: Update Account Model

- [ ] Add group_chats association

```ruby
# app/models/account.rb
# Add after: has_many :agents, dependent: :destroy

has_many :group_chats, dependent: :destroy
```

### Step 7: Create GroupAgentResponseJob

- [ ] Implement background job for agent responses

```ruby
# app/jobs/group_agent_response_job.rb
class GroupAgentResponseJob < ApplicationJob

  STREAM_DEBOUNCE_INTERVAL = 0.2.seconds

  def perform(group_chat, agent)
    @group_chat = group_chat
    @agent = agent
    @ai_message = nil
    @stream_buffer = +""
    @last_stream_flush_at = nil
    @tools_used = []

    context = group_chat.build_context_for_agent(agent)

    chat = RubyLLM.chat(
      model: agent.model_id,
      provider: :openrouter,
      assume_model_exists: true
    )

    agent.tools.each { |tool| chat = chat.with_tool(tool) }

    chat.on_new_message do
      @ai_message = group_chat.group_messages.create!(
        role: "assistant",
        agent: agent,
        content: "",
        streaming: true
      )
    end

    chat.on_tool_call do |tool_call|
      url = tool_call.arguments[:url] || tool_call.arguments["url"]
      @tools_used << (url || tool_call.name.to_s)

      @ai_message&.broadcast_tool_call(
        tool_name: tool_call.name.to_s,
        tool_args: tool_call.arguments
      )
    end

    chat.on_end_message do |ruby_llm_message|
      finalize_message!(ruby_llm_message)
    end

    chat.ask(context) do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end

  rescue RubyLLM::ModelNotFoundError => e
    Rails.logger.error "Model not found: #{e.message}"
    RubyLLM.models.refresh!
    retry_job
  ensure
    flush_stream_buffer(force: true)
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end

  private

  def finalize_message!(ruby_llm_message)
    return unless @ai_message

    flush_stream_buffer(force: true)

    @ai_message.update!({
      content: extract_content(ruby_llm_message.content),
      model_id_string: ruby_llm_message.model_id,
      input_tokens: ruby_llm_message.input_tokens,
      output_tokens: ruby_llm_message.output_tokens,
      tools_used: @tools_used.uniq,
      streaming: false
    })
  end

  def extract_content(content)
    case content
    when RubyLLM::Content
      content.text
    when Hash, Array
      content.to_json
    else
      content
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

end
```

### Step 8: Create GenerateGroupTitleJob

- [ ] Implement title generation for group chats

```ruby
# app/jobs/generate_group_title_job.rb
class GenerateGroupTitleJob < ApplicationJob

  def perform(group_chat)
    return if group_chat.title.present?
    return if group_chat.group_messages.empty?

    first_message = group_chat.group_messages.where(role: "user").first
    return unless first_message&.content.present?

    chat = RubyLLM.chat(model: "openai/gpt-4o-mini", provider: :openrouter, assume_model_exists: true)

    prompt = <<~PROMPT
      Generate a brief, descriptive title (max 50 characters) for a group conversation that starts with this message:

      "#{first_message.content.truncate(500)}"

      Respond with only the title, no quotes or explanation.
    PROMPT

    response = chat.ask(prompt)
    title = response.content.to_s.strip.truncate(50)

    group_chat.update!(title: title) if title.present?
  rescue => e
    Rails.logger.error "Failed to generate group chat title: #{e.message}"
  end

end
```

### Step 9: Create GroupChatsController

- [ ] Implement controller with CRUD and agent response triggering

```ruby
# app/controllers/group_chats_controller.rb
class GroupChatsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_group_chat, except: [:index, :create, :new]

  def index
    @group_chats = current_account.group_chats.includes(:agents).latest

    render inertia: "group_chats/index", props: {
      group_chats: @group_chats.as_json,
      agents: available_agents,
      account: current_account.as_json
    }
  end

  def new
    @group_chats = current_account.group_chats.latest

    render inertia: "group_chats/new", props: {
      group_chats: @group_chats.as_json,
      agents: available_agents,
      account: current_account.as_json,
      file_upload_config: file_upload_config
    }
  end

  def show
    @group_chats = current_account.group_chats.latest
    @messages = @group_chat.group_messages.includes(:user, :agent).with_attached_attachments.sorted

    render inertia: "group_chats/show", props: {
      group_chat: @group_chat.as_json,
      group_chats: @group_chats.as_json,
      messages: @messages.collect(&:as_json),
      agents: @group_chat.agents.as_json,
      account: current_account.as_json,
      file_upload_config: file_upload_config
    }
  end

  def create
    @group_chat = current_account.group_chats.create_with_message!(
      group_chat_params,
      agent_ids: params[:agent_ids] || [],
      message_content: params[:message],
      user: Current.user,
      files: params[:files]
    )
    audit("create_group_chat", @group_chat, agent_ids: params[:agent_ids])
    redirect_to account_group_chat_path(current_account, @group_chat)
  rescue ActiveRecord::RecordInvalid => e
    redirect_to new_account_group_chat_path(current_account),
                inertia: { errors: e.record.errors.to_hash }
  end

  def update
    if @group_chat.update(group_chat_params)
      head :ok
    else
      render json: { errors: @group_chat.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    audit("destroy_group_chat", @group_chat)
    @group_chat.destroy!
    redirect_to account_group_chats_path(current_account)
  end

  private

  def set_group_chat
    @group_chat = current_account.group_chats.find(params[:id])
  end

  def group_chat_params
    params.fetch(:group_chat, {}).permit(:title)
  end

  def available_agents
    current_account.agents.active.by_name.as_json
  end

  def file_upload_config
    {
      acceptable_types: Message::ACCEPTABLE_FILE_TYPES.values.flatten,
      max_size: Message::MAX_FILE_SIZE
    }
  end

end
```

### Step 10: Create GroupMessagesController

- [ ] Implement message creation and agent response triggering

```ruby
# app/controllers/group_messages_controller.rb
class GroupMessagesController < ApplicationController

  require_feature_enabled :agents
  before_action :set_group_chat
  before_action :set_agent, only: [:trigger_agent]

  def create
    @message = @group_chat.group_messages.build(
      message_params.merge(user: Current.user, role: "user")
    )
    @message.attachments.attach(params[:files]) if params[:files].present?

    if @message.save
      audit("create_group_message", @message, **message_params.to_h)

      respond_to do |format|
        format.html { redirect_to account_group_chat_path(@group_chat.account, @group_chat) }
        format.json { render json: @message, status: :created }
      end
    else
      respond_to do |format|
        format.html do
          redirect_back_or_to account_group_chat_path(@group_chat.account, @group_chat),
                              alert: "Failed to send message: #{@message.errors.full_messages.join(', ')}"
        end
        format.json { render json: { errors: @message.errors.full_messages }, status: :unprocessable_entity }
      end
    end
  end

  def trigger_agent
    @group_chat.trigger_agent_response!(@agent)

    respond_to do |format|
      format.html { redirect_to account_group_chat_path(@group_chat.account, @group_chat) }
      format.json { head :ok }
    end
  rescue ArgumentError => e
    respond_to do |format|
      format.html { redirect_back_or_to account_group_chat_path(@group_chat.account, @group_chat), alert: e.message }
      format.json { render json: { error: e.message }, status: :unprocessable_entity }
    end
  end

  private

  def set_group_chat
    @group_chat = current_account.group_chats.find(params[:group_chat_id])
  end

  def set_agent
    @agent = @group_chat.agents.find(params[:agent_id])
  end

  def message_params
    params.require(:message).permit(:content)
  end

end
```

### Step 11: Update Routes

- [ ] Add group_chats and group_messages resources

```ruby
# config/routes.rb
# Add within the resources :accounts block:

resources :accounts, only: [:show, :edit, :update] do
  resources :members, controller: "account_members", only: [:destroy]
  resources :invitations, only: [:create] do
    member do
      post :resend
    end
  end
  resources :chats do
    resources :messages, only: :create
  end
  resources :agents, except: [:show, :new]
  resources :group_chats do
    resources :group_messages, only: :create do
      collection do
        post "trigger/:agent_id", action: :trigger_agent, as: :trigger_agent
      end
    end
  end
end
```

### Step 12: Update Navigation

- [ ] Add group chat link to navbar

```svelte
<!-- app/frontend/lib/components/navigation/navbar.svelte -->
<!-- Update the links derived to include group chats -->

const links = $derived([
  { href: '/documentation', label: 'Documentation', show: true },
  {
    href: currentAccount?.id ? `/accounts/${currentAccount.id}/chats` : '#',
    label: 'Chats',
    show: !!currentUser && siteSettings?.allow_chats,
  },
  {
    href: currentAccount?.id ? `/accounts/${currentAccount.id}/group_chats` : '#',
    label: 'Group Chat',
    show: !!currentUser && siteSettings?.allow_agents,
  },
  {
    href: currentAccount?.id ? `/accounts/${currentAccount.id}/agents` : '#',
    label: 'Agents',
    show: !!currentUser && siteSettings?.allow_agents,
  },
  { href: '#', label: 'About', show: true },
]);
```

### Step 13: Create GroupChat Index Page

- [ ] Implement group chat list with create link

```svelte
<!-- app/frontend/pages/group_chats/index.svelte -->
<script>
  import { Link } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import { Plus, UsersThree, Robot } from 'phosphor-svelte';
  import { useSync } from '$lib/use-sync';
  import { accountGroupChatsPath, newAccountGroupChatPath, accountGroupChatPath } from '@/routes';

  let { group_chats = [], agents = [], account } = $props();

  useSync({ [`Account:${account.id}:group_chats`]: 'group_chats' });
</script>

<svelte:head>
  <title>Group Chats</title>
</svelte:head>

<div class="p-8 max-w-6xl mx-auto">
  <div class="flex items-center justify-between mb-8">
    <div>
      <h1 class="text-3xl font-bold">Group Chats</h1>
      <p class="text-muted-foreground mt-1">Collaborate with multiple AI agents in shared conversations</p>
    </div>
    {#if agents.length > 0}
      <Link href={newAccountGroupChatPath(account.id)}>
        <Button>
          <Plus class="mr-2 size-4" />
          New Group Chat
        </Button>
      </Link>
    {/if}
  </div>

  {#if agents.length === 0}
    <Card.Root>
      <Card.Content class="py-16 text-center">
        <Robot class="mx-auto size-16 text-muted-foreground mb-4" weight="duotone" />
        <h2 class="text-xl font-semibold mb-2">Create agents first</h2>
        <p class="text-muted-foreground mb-6">
          You need at least one agent to start a group chat.
        </p>
        <Link href={`/accounts/${account.id}/agents`}>
          <Button>
            <Plus class="mr-2 size-4" />
            Create an Agent
          </Button>
        </Link>
      </Card.Content>
    </Card.Root>
  {:else if group_chats.length === 0}
    <Card.Root>
      <Card.Content class="py-16 text-center">
        <UsersThree class="mx-auto size-16 text-muted-foreground mb-4" weight="duotone" />
        <h2 class="text-xl font-semibold mb-2">No group chats yet</h2>
        <p class="text-muted-foreground mb-6">
          Start a new group chat to collaborate with your AI agents.
        </p>
        <Link href={newAccountGroupChatPath(account.id)}>
          <Button>
            <Plus class="mr-2 size-4" />
            Start Your First Group Chat
          </Button>
        </Link>
      </Card.Content>
    </Card.Root>
  {:else}
    <div class="grid gap-4 md:grid-cols-2 lg:grid-cols-3">
      {#each group_chats as groupChat (groupChat.id)}
        <Link href={accountGroupChatPath(account.id, groupChat.id)} class="block">
          <Card.Root class="hover:border-primary/50 transition-colors h-full">
            <Card.Header class="pb-3">
              <div class="flex items-start justify-between">
                <div class="flex items-center gap-3">
                  <div class="p-2 bg-primary/10 rounded-lg">
                    <UsersThree class="size-5 text-primary" weight="duotone" />
                  </div>
                  <Card.Title class="text-lg line-clamp-1">{groupChat.title_or_default}</Card.Title>
                </div>
              </div>
            </Card.Header>
            <Card.Content>
              <div class="flex flex-wrap gap-1 mb-3">
                {#each (groupChat.agent_names || []).slice(0, 3) as agentName}
                  <Badge variant="secondary" class="text-xs">{agentName}</Badge>
                {/each}
                {#if (groupChat.agent_names || []).length > 3}
                  <Badge variant="outline" class="text-xs">+{groupChat.agent_names.length - 3}</Badge>
                {/if}
              </div>
              <div class="text-xs text-muted-foreground flex justify-between">
                <span>{groupChat.message_count} messages</span>
                <span>{groupChat.updated_at_short}</span>
              </div>
            </Card.Content>
          </Card.Root>
        </Link>
      {/each}
    </div>
  {/if}
</div>
```

### Step 14: Create GroupChat New Page

- [ ] Implement agent selection and initial message UI

```svelte
<!-- app/frontend/pages/group_chats/new.svelte -->
<script>
  import { router } from '@inertiajs/svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Checkbox } from '$lib/components/shadcn/checkbox/index.js';
  import { Label } from '$lib/components/shadcn/label/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { ArrowUp, Robot, UsersThree, ArrowLeft } from 'phosphor-svelte';
  import FileUploadInput from '$lib/components/chat/FileUploadInput.svelte';
  import { accountGroupChatsPath, accountGroupChatPath } from '@/routes';

  let { group_chats = [], agents = [], account, file_upload_config = {} } = $props();

  let selectedAgentIds = $state([]);
  let messageContent = $state('');
  let selectedFiles = $state([]);
  let isSubmitting = $state(false);

  const hasSelectedAgents = $derived(selectedAgentIds.length > 0);
  const canSubmit = $derived(hasSelectedAgents && (messageContent.trim() || selectedFiles.length > 0));

  function toggleAgent(agentId) {
    if (selectedAgentIds.includes(agentId)) {
      selectedAgentIds = selectedAgentIds.filter(id => id !== agentId);
    } else {
      selectedAgentIds = [...selectedAgentIds, agentId];
    }
  }

  function handleKeydown(event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      startGroupChat();
    }
  }

  function startGroupChat() {
    if (!canSubmit || isSubmitting) return;

    isSubmitting = true;

    const formData = new FormData();
    selectedAgentIds.forEach(id => formData.append('agent_ids[]', id));
    formData.append('message', messageContent);
    selectedFiles.forEach(file => formData.append('files[]', file));

    router.post(accountGroupChatsPath(account.id), formData, {
      forceFormData: true,
      onFinish: () => { isSubmitting = false; }
    });
  }
</script>

<svelte:head>
  <title>New Group Chat</title>
</svelte:head>

<div class="flex h-[calc(100vh-4rem)]">
  <!-- Left sidebar: Recent group chats -->
  <aside class="w-80 border-r border-border bg-muted/30 flex flex-col">
    <div class="p-4 border-b border-border">
      <h2 class="font-semibold text-sm text-muted-foreground">Recent Group Chats</h2>
    </div>
    <nav class="flex-1 overflow-y-auto p-2 space-y-1">
      {#each group_chats.slice(0, 20) as groupChat (groupChat.id)}
        <a
          href={accountGroupChatPath(account.id, groupChat.id)}
          class="block px-3 py-2 rounded-md text-sm hover:bg-muted transition-colors">
          <div class="font-medium truncate">{groupChat.title_or_default}</div>
          <div class="text-xs text-muted-foreground">{groupChat.updated_at_short}</div>
        </a>
      {/each}
    </nav>
  </aside>

  <!-- Right side: New group chat setup -->
  <main class="flex-1 flex flex-col bg-background">
    <header class="border-b border-border bg-muted/30 px-6 py-4">
      <h1 class="text-lg font-semibold">New Group Chat</h1>
      <p class="text-sm text-muted-foreground mt-1">Select agents to join the conversation</p>
    </header>

    <!-- Agent selection -->
    <div class="flex-1 overflow-y-auto px-6 py-4">
      <div class="max-w-2xl mx-auto">
        <Card.Root>
          <Card.Header>
            <Card.Title class="flex items-center gap-2">
              <Robot weight="duotone" class="size-5" />
              Select Agents
            </Card.Title>
            <Card.Description>
              Choose which AI agents will participate in this conversation.
              You must select at least one agent.
            </Card.Description>
          </Card.Header>
          <Card.Content>
            {#if agents.length === 0}
              <p class="text-muted-foreground py-4">
                No agents available. Create agents first to start a group chat.
              </p>
            {:else}
              <div class="space-y-3">
                {#each agents as agent (agent.id)}
                  <label class="flex items-start gap-3 cursor-pointer group p-3 rounded-lg border hover:bg-muted/50 transition-colors"
                         class:border-primary={selectedAgentIds.includes(agent.id)}
                         class:bg-primary/5={selectedAgentIds.includes(agent.id)}>
                    <Checkbox
                      checked={selectedAgentIds.includes(agent.id)}
                      onCheckedChange={() => toggleAgent(agent.id)}
                      class="mt-0.5" />
                    <div class="flex-1 space-y-1">
                      <div class="font-medium group-hover:text-primary transition-colors">
                        {agent.name}
                      </div>
                      {#if agent.system_prompt}
                        <p class="text-sm text-muted-foreground line-clamp-2">{agent.system_prompt}</p>
                      {/if}
                      <div class="text-xs text-muted-foreground">
                        Model: {agent.model_label || agent.model_id}
                      </div>
                    </div>
                  </label>
                {/each}
              </div>
            {/if}
          </Card.Content>
        </Card.Root>

        {#if !hasSelectedAgents}
          <div class="mt-8 text-center text-muted-foreground">
            <UsersThree class="mx-auto size-12 mb-3" weight="duotone" />
            <p>Select at least one agent to start the conversation</p>
          </div>
        {/if}
      </div>
    </div>

    <!-- Message input -->
    <div class="border-t border-border bg-muted/30 p-4">
      <div class="max-w-2xl mx-auto flex gap-3 items-start">
        <FileUploadInput
          bind:files={selectedFiles}
          disabled={!hasSelectedAgents || isSubmitting}
          allowedTypes={file_upload_config.acceptable_types || []}
          maxSize={file_upload_config.max_size || 52428800} />

        <div class="flex-1">
          <textarea
            bind:value={messageContent}
            onkeydown={handleKeydown}
            placeholder={hasSelectedAgents ? "Type your first message..." : "Select agents first..."}
            disabled={!hasSelectedAgents || isSubmitting}
            class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
                   focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent
                   min-h-[40px] max-h-[120px] disabled:opacity-50"
            rows="1"></textarea>
        </div>
        <Button
          onclick={startGroupChat}
          disabled={!canSubmit || isSubmitting}
          size="sm"
          class="h-10 w-10 p-0">
          <ArrowUp size={16} />
        </Button>
      </div>
    </div>
  </main>
</div>
```

### Step 15: Create GroupChat Show Page

- [ ] Implement message display with agent trigger buttons

```svelte
<!-- app/frontend/pages/group_chats/show.svelte -->
<script>
  import { page } from '@inertiajs/svelte';
  import { router } from '@inertiajs/svelte';
  import { createDynamicSync, streamingSync } from '$lib/use-sync';
  import { onMount, onDestroy } from 'svelte';
  import { Button } from '$lib/components/shadcn/button/index.js';
  import { Badge } from '$lib/components/shadcn/badge/index.js';
  import * as Card from '$lib/components/shadcn/card/index.js';
  import { ArrowUp, Spinner, Robot, User, Trash } from 'phosphor-svelte';
  import FileUploadInput from '$lib/components/chat/FileUploadInput.svelte';
  import FileAttachment from '$lib/components/chat/FileAttachment.svelte';
  import { accountGroupChatGroupMessagesPath, triggerAgentAccountGroupChatGroupMessagesPath, accountGroupChatsPath, accountGroupChatPath } from '@/routes';
  import { Streamdown } from 'svelte-streamdown';
  import { formatTime, formatDate, formatDateTime } from '$lib/utils';
  import * as logging from '$lib/logging';

  let { group_chat, group_chats = [], messages = [], agents = [], account, file_upload_config = {} } = $props();

  let messageInput = $state('');
  let selectedFiles = $state([]);
  let messagesContainer;
  let isSubmitting = $state(false);
  let triggeringAgent = $state(null);

  const updateSync = createDynamicSync();
  let syncSignature = null;

  onMount(() => {
    if (messagesContainer) {
      messagesContainer.scrollTop = messagesContainer.scrollHeight;
    }
  });

  $effect(() => {
    const subs = {};
    subs[`Account:${account.id}:group_chats`] = 'group_chats';

    if (group_chat) {
      subs[`GroupChat:${group_chat.id}`] = 'group_chat';
      subs[`GroupChat:${group_chat.id}:group_messages`] = 'messages';
    }

    const messageSignature = Array.isArray(messages) ? messages.map(m => m.id).join(':') : '';
    const nextSignature = `${account.id}|${group_chat?.id ?? 'none'}|${messageSignature}`;

    if (nextSignature !== syncSignature) {
      syncSignature = nextSignature;
      updateSync(subs);
    }

    if (group_chat && messages.length !== group_chat.message_count) {
      router.reload({ only: ['messages'], preserveState: true, preserveScroll: true });
    }
  });

  $effect(() => {
    messages;
    if (messagesContainer) {
      setTimeout(() => { messagesContainer.scrollTop = messagesContainer.scrollHeight; }, 100);
    }
  });

  streamingSync(
    (data) => {
      if (data.id) {
        const index = messages.findIndex(m => m.id === data.id);
        if (index !== -1) {
          const updated = { ...messages[index], content: `${messages[index].content || ''}${data.chunk || ''}`, streaming: true };
          messages = messages.map((m, i) => i === index ? updated : m);
        }
      }
    },
    (data) => {
      if (data.id) {
        const index = messages.findIndex(m => m.id === data.id);
        if (index !== -1) {
          messages = messages.map((m, i) => i === index ? { ...m, streaming: false } : m);
          triggeringAgent = null;
        }
      }
    }
  );

  function sendMessage() {
    if ((!messageInput.trim() && selectedFiles.length === 0) || isSubmitting) return;

    isSubmitting = true;

    const formData = new FormData();
    formData.append('message[content]', messageInput);
    selectedFiles.forEach(file => formData.append('files[]', file));

    router.post(accountGroupChatGroupMessagesPath(account.id, group_chat.id), formData, {
      onSuccess: () => {
        messageInput = '';
        selectedFiles = [];
      },
      onFinish: () => { isSubmitting = false; }
    });
  }

  function triggerAgent(agent) {
    if (triggeringAgent) return;

    triggeringAgent = agent.id;

    router.post(triggerAgentAccountGroupChatGroupMessagesPath(account.id, group_chat.id, agent.id), {}, {
      onError: () => { triggeringAgent = null; }
    });
  }

  function handleKeydown(event) {
    if (event.key === 'Enter' && !event.shiftKey) {
      event.preventDefault();
      sendMessage();
    }
  }

  function deleteGroupChat() {
    if (!confirm('Delete this group chat? This cannot be undone.')) return;
    router.delete(accountGroupChatPath(account.id, group_chat.id));
  }

  function shouldShowTimestamp(index) {
    if (!Array.isArray(messages) || messages.length === 0 || !messages[index]) return false;

    const message = messages[index];
    const currentCreatedAt = new Date(message.created_at);
    if (Number.isNaN(currentCreatedAt)) return false;

    if (index === 0) return true;

    const previousMessage = messages[index - 1];
    if (!previousMessage) return true;

    const previousCreatedAt = new Date(previousMessage.created_at);
    if (Number.isNaN(previousCreatedAt)) return true;

    const sameDay = currentCreatedAt.toDateString() === previousCreatedAt.toDateString();
    if (!sameDay) return true;

    const timeDifference = currentCreatedAt.getTime() - previousCreatedAt.getTime();
    return timeDifference >= 60 * 60 * 1000;
  }

  function timestampLabel(index) {
    const message = messages[index];
    if (!message) return '';

    const createdAt = new Date(message.created_at);
    if (Number.isNaN(createdAt)) return '';

    if (index === 0) return formatDate(createdAt);

    const previousMessage = messages[index - 1];
    const previousCreatedAt = previousMessage ? new Date(previousMessage.created_at) : null;

    if (!previousCreatedAt || Number.isNaN(previousCreatedAt) || createdAt.toDateString() !== previousCreatedAt.toDateString()) {
      return formatDate(createdAt);
    }

    return formatTime(createdAt);
  }
</script>

<svelte:head>
  <title>{group_chat?.title_or_default || 'Group Chat'}</title>
</svelte:head>

<div class="flex h-[calc(100vh-4rem)]">
  <!-- Left sidebar: Recent group chats -->
  <aside class="w-80 border-r border-border bg-muted/30 flex flex-col">
    <div class="p-4 border-b border-border flex items-center justify-between">
      <h2 class="font-semibold text-sm text-muted-foreground">Group Chats</h2>
      <a href={`/accounts/${account.id}/group_chats/new`} class="text-primary hover:text-primary/80">
        <span class="text-lg">+</span>
      </a>
    </div>
    <nav class="flex-1 overflow-y-auto p-2 space-y-1">
      {#each group_chats.slice(0, 20) as gc (gc.id)}
        <a
          href={accountGroupChatPath(account.id, gc.id)}
          class="block px-3 py-2 rounded-md text-sm hover:bg-muted transition-colors"
          class:bg-muted={gc.id === group_chat?.id}>
          <div class="font-medium truncate">{gc.title_or_default}</div>
          <div class="text-xs text-muted-foreground">{gc.updated_at_short}</div>
        </a>
      {/each}
    </nav>
  </aside>

  <!-- Right side: Chat area -->
  <main class="flex-1 flex flex-col bg-background">
    <!-- Header -->
    <header class="border-b border-border bg-muted/30 px-6 py-4 flex items-center justify-between">
      <div>
        <h1 class="text-lg font-semibold truncate">{group_chat?.title_or_default || 'Group Chat'}</h1>
        <div class="flex flex-wrap gap-1 mt-2">
          {#each agents as agent (agent.id)}
            <Badge variant="secondary" class="text-xs">{agent.name}</Badge>
          {/each}
        </div>
      </div>
      <Button variant="ghost" size="sm" onclick={deleteGroupChat} class="text-destructive hover:text-destructive">
        <Trash size={16} />
      </Button>
    </header>

    <!-- Messages -->
    <div bind:this={messagesContainer} class="flex-1 overflow-y-auto px-6 py-4 space-y-4">
      {#if !Array.isArray(messages) || messages.length === 0}
        <div class="flex items-center justify-center h-full">
          <div class="text-center text-muted-foreground">
            <p>Start the conversation by sending a message below.</p>
          </div>
        </div>
      {:else}
        {#each messages as message, index (message.id)}
          {#if shouldShowTimestamp(index)}
            <div class="flex items-center gap-4 my-6">
              <div class="flex-1 border-t border-border"></div>
              <div class="px-3 py-1 bg-muted rounded-full text-xs font-medium text-muted-foreground">
                {timestampLabel(index)}
              </div>
              <div class="flex-1 border-t border-border"></div>
            </div>
          {/if}

          <div class="space-y-1">
            <div class={message.author_type === 'human' ? 'flex justify-end' : 'flex justify-start'}>
              <div class="max-w-[70%]">
                <!-- Author label -->
                <div class="flex items-center gap-2 mb-1 {message.author_type === 'human' ? 'justify-end' : 'justify-start'}">
                  {#if message.author_type === 'agent'}
                    <Robot size={14} class="text-primary" weight="duotone" />
                  {:else}
                    <User size={14} class="text-muted-foreground" />
                  {/if}
                  <span class="text-xs font-medium text-muted-foreground">{message.author_name}</span>
                </div>

                <Card.Root class={message.author_type === 'human' ? 'bg-indigo-200' : ''}>
                  <Card.Content class="p-4">
                    {#if message.files_json && message.files_json.length > 0}
                      <div class="space-y-2 mb-3">
                        {#each message.files_json as file}
                          <FileAttachment {file} />
                        {/each}
                      </div>
                    {/if}

                    {#if message.streaming && (!message.content || message.content.trim() === '')}
                      <div class="flex items-center gap-2 text-muted-foreground">
                        <Spinner size={16} class="animate-spin" />
                        <span class="text-sm">{message.tool_status || 'Generating response...'}</span>
                      </div>
                    {:else}
                      <Streamdown
                        content={message.content}
                        parseIncompleteMarkdown
                        baseTheme="shadcn"
                        class="prose"
                        animation={{
                          enabled: true,
                          type: 'fade',
                          tokenize: 'word',
                          duration: 300,
                          timingFunction: 'ease-out',
                          animateOnMount: message.author_type === 'agent',
                        }} />
                    {/if}

                    {#if message.tools_used && message.tools_used.length > 0}
                      <div class="flex flex-wrap gap-1 mt-3 pt-3 border-t border-border/50">
                        {#each message.tools_used as tool}
                          <Badge variant="outline" class="text-xs">{tool}</Badge>
                        {/each}
                      </div>
                    {/if}
                  </Card.Content>
                </Card.Root>

                <div class="text-xs text-muted-foreground mt-1 {message.author_type === 'human' ? 'text-right' : ''}">
                  {formatTime(message.created_at)}
                  {#if message.streaming}
                    <span class="ml-2 text-green-600 animate-pulse">streaming</span>
                  {/if}
                </div>
              </div>
            </div>
          </div>
        {/each}
      {/if}
    </div>

    <!-- Agent trigger buttons -->
    <div class="border-t border-border px-6 py-3 bg-muted/20">
      <div class="flex items-center gap-2 flex-wrap">
        <span class="text-xs text-muted-foreground mr-2">Ask agent:</span>
        {#each agents as agent (agent.id)}
          <Button
            variant="outline"
            size="sm"
            onclick={() => triggerAgent(agent)}
            disabled={triggeringAgent !== null}
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

    <!-- Message input -->
    <div class="border-t border-border bg-muted/30 p-4">
      <div class="flex gap-3 items-start">
        <FileUploadInput
          bind:files={selectedFiles}
          disabled={isSubmitting}
          allowedTypes={file_upload_config.acceptable_types || []}
          maxSize={file_upload_config.max_size || 52428800} />

        <div class="flex-1">
          <textarea
            bind:value={messageInput}
            onkeydown={handleKeydown}
            placeholder="Type your message..."
            disabled={isSubmitting}
            class="w-full resize-none border border-input rounded-md px-3 py-2 text-sm bg-background
                   focus:outline-none focus:ring-2 focus:ring-ring focus:border-transparent
                   min-h-[40px] max-h-[120px]"
            rows="1"></textarea>
        </div>
        <Button
          onclick={sendMessage}
          disabled={(!messageInput.trim() && selectedFiles.length === 0) || isSubmitting}
          size="sm"
          class="h-10 w-10 p-0">
          <ArrowUp size={16} />
        </Button>
      </div>
    </div>
  </main>
</div>
```

### Step 16: Regenerate JS Routes

- [ ] Run the js-routes generator

```bash
rails js_routes:generate
```

## Testing Strategy

### Model Tests

- [ ] Create group chat model tests

```ruby
# test/models/group_chat_test.rb
require "test_helper"

class GroupChatTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:one)
    @agent = @account.agents.create!(name: "Test Agent", model_id: "openrouter/auto")
  end

  test "requires at least one agent" do
    group_chat = @account.group_chats.build
    assert_not group_chat.valid?
    assert_includes group_chat.errors[:agents], "must include at least one agent"
  end

  test "creates with agents" do
    group_chat = @account.group_chats.create!(agents: [@agent])
    assert group_chat.persisted?
    assert_equal 1, group_chat.agents.count
  end

  test "title_or_default returns agent names when no title" do
    group_chat = @account.group_chats.create!(agents: [@agent])
    assert_includes group_chat.title_or_default, @agent.name
  end

  test "trigger_agent_response! raises for non-participant" do
    group_chat = @account.group_chats.create!(agents: [@agent])
    other_agent = @account.agents.create!(name: "Other Agent")

    assert_raises ArgumentError do
      group_chat.trigger_agent_response!(other_agent)
    end
  end

  test "build_context_for_agent includes system prompt" do
    @agent.update!(system_prompt: "You are helpful")
    group_chat = @account.group_chats.create!(agents: [@agent])

    context = group_chat.build_context_for_agent(@agent)
    system_message = context.find { |m| m[:role] == "system" }

    assert_includes system_message[:content], "You are helpful"
  end
end
```

### Controller Tests

- [ ] Create controller tests

```ruby
# test/controllers/group_chats_controller_test.rb
require "test_helper"

class GroupChatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @account = accounts(:one)
    sign_in @user
    Setting.instance.update!(allow_agents: true)
    @agent = @account.agents.create!(name: "Test Agent", model_id: "openrouter/auto")
  end

  test "index shows group chats" do
    @account.group_chats.create!(agents: [@agent])
    get account_group_chats_path(@account)
    assert_response :success
  end

  test "creates group chat with agents" do
    assert_difference "@account.group_chats.count", 1 do
      post account_group_chats_path(@account), params: {
        agent_ids: [@agent.id],
        message: "Hello!"
      }
    end
  end

  test "show displays messages and agents" do
    group_chat = @account.group_chats.create!(agents: [@agent])
    get account_group_chat_path(@account, group_chat)
    assert_response :success
  end

  test "blocks access when agents feature disabled" do
    Setting.instance.update!(allow_agents: false)
    get account_group_chats_path(@account)
    assert_redirected_to root_path
  end
end

# test/controllers/group_messages_controller_test.rb
require "test_helper"

class GroupMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:one)
    @account = accounts(:one)
    sign_in @user
    Setting.instance.update!(allow_agents: true)
    @agent = @account.agents.create!(name: "Test Agent", model_id: "openrouter/auto")
    @group_chat = @account.group_chats.create!(agents: [@agent])
  end

  test "creates user message" do
    assert_difference "@group_chat.group_messages.count", 1 do
      post account_group_chat_group_messages_path(@account, @group_chat), params: {
        message: { content: "Hello!" }
      }
    end
  end

  test "trigger_agent enqueues job" do
    assert_enqueued_with(job: GroupAgentResponseJob) do
      post trigger_agent_account_group_chat_group_messages_path(@account, @group_chat, @agent)
    end
  end
end
```

## Implementation Checklist

### Database
- [ ] Create migration for group_chats, group_chat_participants, group_messages, group_tool_calls
- [ ] Run migration

### Models
- [ ] Create GroupChat model
- [ ] Create GroupChatParticipant model
- [ ] Create GroupMessage model
- [ ] Create GroupToolCall model
- [ ] Add group_chats association to Account

### Jobs
- [ ] Create GroupAgentResponseJob
- [ ] Create GenerateGroupTitleJob

### Controllers
- [ ] Create GroupChatsController
- [ ] Create GroupMessagesController

### Routes
- [ ] Add group_chats and group_messages resources
- [ ] Regenerate js-routes

### Frontend
- [ ] Create group_chats/index.svelte
- [ ] Create group_chats/new.svelte
- [ ] Create group_chats/show.svelte
- [ ] Update navbar.svelte with Group Chat link

### Testing
- [ ] Write model tests
- [ ] Write controller tests
- [ ] Manual testing with multiple agents

## File Summary

| File | Lines (approx) | Purpose |
|------|----------------|---------|
| Migration | ~50 | Create all group chat tables |
| GroupChat model | ~90 | Main model with context building |
| GroupChatParticipant model | ~10 | Join model |
| GroupMessage model | ~130 | Messages with attribution |
| GroupToolCall model | ~10 | Tool call tracking |
| GroupAgentResponseJob | ~100 | Handle agent responses |
| GenerateGroupTitleJob | ~30 | Auto-generate titles |
| GroupChatsController | ~70 | CRUD for group chats |
| GroupMessagesController | ~60 | Messages + agent triggering |
| group_chats/index.svelte | ~80 | List view |
| group_chats/new.svelte | ~130 | Agent selection + first message |
| group_chats/show.svelte | ~250 | Chat view with agent buttons |
| **Total** | **~1010** | Complete feature |

## Design Decisions Summary

| Decision | Rationale |
|----------|-----------|
| Separate tables (not polymorphic) | Clean separation, simpler queries, easier evolution |
| `agent_id` on messages | Clear attribution for AI context and UI |
| Manual agent triggering | Core requirement - no auto-response |
| Context includes participant names | Agents understand who said what |
| Reuse existing patterns | Broadcastable, streaming, file uploads |
| Feature gated by `allow_agents` | Group chat requires agents to exist |

## Future Considerations

This implementation provides a foundation for future enhancements:

1. **Tagging/Mentions** - `@AgentName` to specifically address an agent
2. **Auto-scheduling** - Periodic responses from specific agents
3. **Agent-initiated messages** - Agents that can proactively contribute
4. **Agent memory** - Persistent context across conversations
5. **Human invitations** - Invite other account members to join
