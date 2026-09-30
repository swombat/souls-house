# Implementation Plan: Agentic Conversation System with Dynamic Tool Management

## Executive Summary

This plan implements an agentic conversation system that enables AI models to use tools (function calling) within chats. The system allows dynamic management of tools through a UI toggle interface, similar to ChatGPT/Claude. Tools are grouped and can be added or removed mid-conversation. The initial proof of concept includes a web fetch tool using curl. The implementation follows Rails conventions with fat models, no service objects, and leverages RubyLLM's existing `acts_as_chat` capabilities.

## Architecture Overview

### Core Design Decisions

1. **Tool Groups as Associations** - Tool groups are stored as a JSONB column on Chat model, no separate table
2. **Tool Implementation** - Tools inherit from `RubyLLM::Tool` and live in `app/tools/`
3. **Dynamic Tool Loading** - Tools are registered at runtime based on enabled groups
4. **UI Toggles** - Svelte component with switches to enable/disable tool groups
5. **Visual Indicators** - Tool usage shown inline in messages with status badges
6. **Error Handling** - Full errors passed to LLM, let the model decide how to respond

### Data Flow

```
User enables tools → Updates chat.tool_groups →
Chat loads tools → Passes to RubyLLM →
LLM decides to use tool → Tool executes →
Result returned to LLM → Final response shown
```

## Implementation Steps

### Step 1: Update Chat Model

- [ ] Add `tool_groups` JSONB column to chats table
- [ ] Add methods for tool management
- [ ] Integrate with RubyLLM's tool system

```ruby
# db/migrate/XXXXX_add_tool_groups_to_chats.rb
class AddToolGroupsToChats < ActiveRecord::Migration[8.0]
  def change
    add_column :chats, :tool_groups, :jsonb, default: {}
    add_index :chats, :tool_groups, using: :gin
  end
end
```

```ruby
# app/models/chat.rb
class Chat < ApplicationRecord
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include JsonAttributes

  acts_as_chat

  belongs_to :account

  json_attributes :title, :model_id, :model_name, :updated_at_formatted,
                  :message_count, :tool_groups, :enabled_tools

  # Available tool groups
  TOOL_GROUPS = {
    'web' => {
      label: 'Web Access',
      description: 'Allow AI to fetch and read web pages',
      tools: ['WebFetch']
    },
    'files' => {
      label: 'File Operations',
      description: 'Read and write files (coming soon)',
      tools: ['FileReader', 'FileWriter'],
      disabled: true # Feature flag
    }
  }.freeze

  # Enable/disable a tool group
  def toggle_tool_group!(group_name)
    self.tool_groups ||= {}
    self.tool_groups[group_name] = !tool_groups[group_name]
    save!
    broadcast_refresh # Update UI
  end

  # Get enabled tools for RubyLLM
  def enabled_tools
    return [] unless tool_groups.present?

    tool_groups.select { |_, enabled| enabled }.keys.flat_map do |group|
      next [] unless TOOL_GROUPS[group]
      TOOL_GROUPS[group][:tools].map { |tool_name| tool_class(tool_name) }.compact
    end
  end

  private

  def tool_class(name)
    "#{name}Tool".constantize
  rescue NameError
    Rails.logger.warn "Tool not found: #{name}"
    nil
  end
end
```

### Step 2: Create Base Tool and Web Fetch Tool

- [ ] Create base tool class with common functionality
- [ ] Implement WebFetch tool using curl
- [ ] Add error handling and timeout

```ruby
# app/tools/application_tool.rb
class ApplicationTool < RubyLLM::Tool
  # Common functionality for all tools

  def self.tool_name
    name.underscore.gsub('_tool', '')
  end

  protected

  def log_execution(params)
    Rails.logger.info "[#{self.class.tool_name}] Executing with params: #{params.inspect}"
  end

  def handle_error(error)
    Rails.logger.error "[#{self.class.tool_name}] Error: #{error.message}"
    { error: error.message, success: false }
  end
end
```

```ruby
# app/tools/web_fetch_tool.rb
class WebFetchTool < ApplicationTool
  description "Fetch and read content from a web page"

  param :url, type: 'string', description: 'The URL to fetch', required: true
  param :selector, type: 'string', description: 'CSS selector to extract specific content (optional)'

  def execute(url:, selector: nil)
    log_execution(url: url, selector: selector)

    # Validate URL
    uri = URI.parse(url)
    raise ArgumentError, "Invalid URL" unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)

    # Fetch content using curl for simplicity
    result = fetch_with_curl(url)

    # Optional: Extract specific content with selector
    if selector.present?
      result = extract_content(result, selector)
    end

    {
      success: true,
      url: url,
      content: result,
      fetched_at: Time.current.iso8601
    }
  rescue => e
    handle_error(e)
  end

  private

  def fetch_with_curl(url)
    # Use timeout to prevent hanging
    output = `curl -s -L --max-time 10 --user-agent "RubyLLM/1.0" "#{url}" 2>&1`

    if $?.success?
      # Convert HTML to readable text
      strip_html(output)
    else
      raise "Failed to fetch URL: #{output}"
    end
  end

  def strip_html(html)
    # Basic HTML stripping - in production use Nokogiri
    html.gsub(/<script.*?<\/script>/m, '')
        .gsub(/<style.*?<\/style>/m, '')
        .gsub(/<[^>]+>/, ' ')
        .gsub(/\s+/, ' ')
        .strip
        .first(5000) # Limit content length
  end

  def extract_content(html, selector)
    # Simplified - in production use Nokogiri
    "Content extraction not yet implemented. Full page content returned."
  end
end
```

### Step 3: Update Message Model for Tool Calls

- [ ] Add tool_calls tracking to messages
- [ ] Add visual indicators for tool usage

```ruby
# db/migrate/XXXXX_add_tool_calls_to_messages.rb
class AddToolCallsToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :tool_calls, :jsonb, default: []
  end
end
```

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  # ... existing code ...

  json_attributes :role, :content, :user_name, :user_avatar_url, :completed,
                  :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tool_calls, :has_tool_calls

  def has_tool_calls
    tool_calls.present? && tool_calls.any?
  end

  # Store tool call information when message is created
  after_create :extract_tool_calls

  private

  def extract_tool_calls
    # RubyLLM will populate this via callbacks
  end
end
```

### Step 4: Integrate Tools with AI Response Job

- [ ] Pass enabled tools to RubyLLM
- [ ] Handle tool execution callbacks
- [ ] Store tool call information

```ruby
# app/jobs/ai_response_job.rb
class AiResponseJob < ApplicationJob
  def perform(chat)
    @chat = chat
    @ai_message = nil
    @stream_buffer = +""
    @last_stream_flush_at = nil

    # Configure tools for this chat
    configure_tools!

    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
      @ai_message.update!(streaming: true) if @ai_message
    end

    chat.on_tool_call do |tool_name, params, result|
      log_tool_call(tool_name, params, result)
    end

    chat.on_end_message do |ruby_llm_message|
      finalize_message!(ruby_llm_message)
    end

    chat.complete do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end
  rescue => e
    handle_error(e)
  ensure
    flush_stream_buffer(force: true)
    @ai_message&.stop_streaming if @ai_message&.streaming?
  end

  private

  def configure_tools!
    # Set tools based on chat's enabled tool groups
    @chat.tools = @chat.enabled_tools if @chat.enabled_tools.any?
  end

  def log_tool_call(tool_name, params, result)
    return unless @ai_message

    @ai_message.tool_calls ||= []
    @ai_message.tool_calls << {
      tool: tool_name,
      params: params,
      result: result[:success] ? 'success' : 'failed',
      timestamp: Time.current.iso8601
    }

    # Save without callbacks to avoid broadcast spam
    @ai_message.update_columns(tool_calls: @ai_message.tool_calls)

    # Broadcast tool usage indicator
    @ai_message.broadcast_marker(
      "Message:#{@ai_message.to_param}",
      {
        action: "tool_used",
        tool: tool_name,
        id: @ai_message.to_param
      }
    )
  end

  def handle_error(error)
    Rails.logger.error "AI Response error: #{error.message}"

    # Pass full error to the model if it's a tool error
    if error.is_a?(RubyLLM::ToolExecutionError)
      # Let the model see the error and decide how to respond
      @chat.messages.create!(
        role: 'system',
        content: "Tool execution failed: #{error.message}"
      )
      retry_job
    else
      super
    end
  end
end
```

### Step 5: Create UI Components for Tool Management

- [ ] Add tool toggles to chat interface
- [ ] Show enabled tools in chat header
- [ ] Add visual indicators for tool usage

```svelte
<!-- app/frontend/components/chat/ToolManager.svelte -->
<script>
  import { router } from '@inertiajs/svelte';
  import { Switch } from '$lib/components/shadcn/switch';
  import { Badge } from '$lib/components/shadcn/badge';
  import { Wrench, Globe, Folder } from 'phosphor-svelte';

  export let chat;
  export let toolGroups;

  const icons = {
    web: Globe,
    files: Folder,
    default: Wrench
  };

  function toggleTool(groupName) {
    router.post(`/accounts/${chat.account_id}/chats/${chat.id}/toggle_tool`, {
      tool_group: groupName
    }, {
      preserveState: true,
      preserveScroll: true
    });
  }
</script>

<div class="border-b border-border px-4 py-2 bg-muted/20">
  <div class="flex items-center gap-4">
    <span class="text-sm font-medium">Tools:</span>
    {#each Object.entries(toolGroups) as [key, group]}
      <div class="flex items-center gap-2">
        <svelte:component this={icons[key] || icons.default} size={16} />
        <label class="flex items-center gap-2 cursor-pointer">
          <span class="text-sm">{group.label}</span>
          <Switch
            checked={chat.tool_groups?.[key] || false}
            disabled={group.disabled}
            onCheckedChange={() => toggleTool(key)}
          />
        </label>
        {#if group.disabled}
          <Badge variant="secondary" class="text-xs">Soon</Badge>
        {/if}
      </div>
    {/each}
  </div>
</div>
```

```svelte
<!-- Update app/frontend/pages/chats/show.svelte -->
<script>
  // Add to imports
  import ToolManager from '$lib/components/chat/ToolManager.svelte';
  import { Badge } from '$lib/components/shadcn/badge';

  // In props
  let { chat, chats = [], messages = [], account, models = [],
        file_upload_config = {}, tool_groups = {} } = $props();
</script>

<!-- Add after chat header -->
<ToolManager {chat} {toolGroups} />

<!-- Update message display to show tool usage -->
{#if message.has_tool_calls}
  <div class="flex gap-2 mt-2">
    {#each message.tool_calls as tool}
      <Badge variant="outline" class="text-xs">
        <Wrench size={12} class="mr-1" />
        Used {tool.tool}
      </Badge>
    {/each}
  </div>
{/if}
```

### Step 6: Add Controller Actions

- [ ] Add toggle_tool action to ChatsController
- [ ] Pass tool groups to frontend

```ruby
# app/controllers/chats_controller.rb
class ChatsController < ApplicationController
  # ... existing code ...

  def show
    @chats = current_account.chats.latest
    @messages = @chat.messages.with_attached_attachments.sorted

    render inertia: "chats/show", props: {
      chat: @chat.as_json,
      chats: @chats.as_json,
      messages: @messages.all.collect(&:as_json),
      account: current_account.as_json,
      models: available_models,
      tool_groups: Chat::TOOL_GROUPS,
      file_upload_config: {
        acceptable_types: Message::ACCEPTABLE_FILE_TYPES.values.flatten,
        max_size: Message::MAX_FILE_SIZE
      }
    }
  end

  def toggle_tool
    @chat = current_account.chats.find(params[:id])
    @chat.toggle_tool_group!(params[:tool_group])

    head :ok
  end

  # ... rest of controller ...
end
```

```ruby
# config/routes.rb
# Add to existing chat routes
resources :chats do
  member do
    post :toggle_tool
  end
  # ... existing nested routes ...
end
```

### Step 7: Testing Strategy

- [ ] Unit tests for tools
- [ ] Integration tests for tool execution
- [ ] System tests for UI toggles

```ruby
# test/tools/web_fetch_tool_test.rb
class WebFetchToolTest < ActiveSupport::TestCase
  setup do
    @tool = WebFetchTool.new
  end

  test "fetches content from valid URL" do
    # Stub curl command
    @tool.stub :`, "< html>Test Content</html>" do
      result = @tool.execute(url: "https://example.com")
      assert result[:success]
      assert_match "Test Content", result[:content]
    end
  end

  test "handles invalid URL" do
    result = @tool.execute(url: "not-a-url")
    assert_not result[:success]
    assert result[:error]
  end

  test "respects timeout" do
    # Test that long-running requests timeout
  end
end
```

```ruby
# test/models/chat_test.rb
class ChatTest < ActiveSupport::TestCase
  test "toggles tool groups" do
    chat = chats(:one)
    assert_nil chat.tool_groups['web']

    chat.toggle_tool_group!('web')
    assert chat.tool_groups['web']

    chat.toggle_tool_group!('web')
    assert_not chat.tool_groups['web']
  end

  test "returns enabled tools" do
    chat = chats(:one)
    chat.update!(tool_groups: { 'web' => true })

    tools = chat.enabled_tools
    assert_includes tools, WebFetchTool
  end
end
```

## Key Components

### Models
- **Chat** - Extended with tool_groups JSONB column and tool management methods
- **Message** - Extended with tool_calls tracking

### Tools
- **ApplicationTool** - Base class for all tools
- **WebFetchTool** - Proof of concept web fetching tool

### UI Components
- **ToolManager** - Svelte component for toggling tool groups
- **Tool usage badges** - Visual indicators in messages

### Jobs
- **AiResponseJob** - Enhanced to configure and track tool usage

## External Dependencies

No new gems required - RubyLLM already supports tools natively. For production:
- Consider adding **Nokogiri** for better HTML parsing in WebFetch tool
- Consider **Faraday** for more robust HTTP requests instead of curl

## Edge Cases and Error Handling

1. **Tool Timeout** - Tools have 10-second timeout to prevent hanging
2. **Invalid URLs** - Validated before execution, error returned to LLM
3. **Large Content** - Limited to 5000 characters to prevent token overflow
4. **Tool Not Found** - Logged warning, tool skipped
5. **Tool Execution Errors** - Full error passed to LLM to handle gracefully
6. **Mid-conversation Toggle** - New tools available immediately on next message

## Future Enhancements

1. **More Tools** - File operations, database queries, API calls
2. **Tool Permissions** - Account-level tool restrictions
3. **Tool Analytics** - Track usage, success rates, popular tools
4. **Custom Tools** - Allow users to define their own tools
5. **Tool Composition** - Tools that can call other tools
6. **Caching** - Cache tool results to reduce API calls

## Rails-Worthiness Assessment

This implementation follows Rails philosophy:
- ✅ **Fat models** - Business logic in Chat model, not service objects
- ✅ **Convention over configuration** - Tools auto-discovered by naming
- ✅ **No unnecessary abstractions** - Direct integration with RubyLLM
- ✅ **Database-backed** - JSONB for flexible tool configuration
- ✅ **Progressive enhancement** - Start simple, enhance over time
- ✅ **Developer happiness** - Clear, readable, maintainable code

The plan is ready for implementation.