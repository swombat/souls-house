# Revised Implementation Plan: Simple Web Fetch Tool for Chats

## Executive Summary

Add a web fetch tool to chats that allows the AI to retrieve URL content. This is implemented as a simple boolean flag on the Chat model, one Ruby class for the tool, and minimal UI changes. No abstractions, no frameworks, no complexity - just the simplest thing that works.

## Architecture Overview

### What We're Building
1. A boolean column `can_fetch_urls` on the chats table
2. A single `WebFetchTool` class that fetches URL content
3. A checkbox in the chat UI to toggle web access
4. Visual indicator when the tool is used

### What We're NOT Building
- No base classes or abstract tools
- No JSONB columns or complex data structures
- No service objects or unnecessary abstractions
- No metaprogramming or dynamic loading
- No shell commands when Ruby has the answer

## Implementation Steps

### Step 1: Add Boolean Flag to Chat Model

- [ ] Add migration for web fetch capability

```ruby
# db/migrate/XXXXX_add_can_fetch_urls_to_chats.rb
class AddCanFetchUrlsToChats < ActiveRecord::Migration[8.0]
  def change
    add_column :chats, :can_fetch_urls, :boolean, default: false, null: false
    add_index :chats, :can_fetch_urls
  end
end
```

- [ ] Update Chat model with tool configuration

```ruby
# app/models/chat.rb
class Chat < ApplicationRecord
  include Broadcastable
  include ObfuscatesId
  include SyncAuthorizable
  include JsonAttributes

  acts_as_chat

  belongs_to :account
  has_many :messages

  json_attributes :title, :model_id, :model_name, :updated_at_formatted,
                  :message_count, :can_fetch_urls

  # Configure tools for RubyLLM when web fetching is enabled
  def available_tools
    return [] unless can_fetch_urls?
    [WebFetchTool]
  end
end
```

### Step 2: Create the Web Fetch Tool

- [ ] Implement a single, simple tool class

```ruby
# app/tools/web_fetch_tool.rb
class WebFetchTool < RubyLLM::Tool
  description "Fetch and read content from a web page"

  param :url, type: 'string', description: 'The URL to fetch', required: true

  def execute(url:)
    require 'net/http'
    require 'uri'

    uri = URI.parse(url)

    # Simple validation
    unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return { error: "Invalid URL: must be http or https" }
    end

    # Fetch with timeout
    response = Net::HTTP.start(uri.host, uri.port,
                              use_ssl: uri.scheme == 'https',
                              open_timeout: 5,
                              read_timeout: 10) do |http|
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'RubyLLM/1.0'
      http.request(request)
    end

    if response.is_a?(Net::HTTPSuccess)
      # Strip HTML and limit content
      content = ActionView::Base.full_sanitizer.sanitize(response.body)
      content = content.strip.first(5000)

      { content: content, url: url, fetched_at: Time.current.iso8601 }
    else
      { error: "HTTP #{response.code}: #{response.message}" }
    end

  rescue => e
    # Pass full error to LLM - let it figure out what to tell the user
    { error: e.message }
  end
end
```

### Step 3: Track Tool Usage in Messages

- [ ] Add simple array column for tracking

```ruby
# db/migrate/XXXXX_add_tools_used_to_messages.rb
class AddToolsUsedToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :tools_used, :text, array: true, default: []
  end
end
```

- [ ] Update Message model

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  # ... existing code ...

  json_attributes :role, :content, :user_name, :user_avatar_url, :completed,
                  :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tools_used

  # Simple helper to check if tools were used
  def used_tools?
    tools_used.present? && tools_used.any?
  end
end
```

### Step 4: Update AI Response Job

- [ ] Configure tools and track usage

```ruby
# app/jobs/ai_response_job.rb
class AiResponseJob < ApplicationJob
  def perform(chat)
    @chat = chat
    @ai_message = nil
    @stream_buffer = +""
    @last_stream_flush_at = nil
    @tools_used = []

    # Set available tools
    chat.tools = chat.available_tools

    # Track when new message is created
    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
      @ai_message.update!(streaming: true) if @ai_message
    end

    # Track tool usage
    chat.on_tool_call do |tool_name, _params, _result|
      @tools_used << tool_name.to_s.underscore.humanize
    end

    # Finalize message with tool information
    chat.on_end_message do |ruby_llm_message|
      if @ai_message
        @ai_message.update!(
          tools_used: @tools_used.uniq,
          streaming: false,
          completed: true
        )
        @ai_message.broadcast_refresh
      end
    end

    # Stream content as before
    chat.complete do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end

  rescue => e
    Rails.logger.error "AI Response error: #{e.message}"
    # If it's a tool error, let the LLM see it and respond naturally
    if e.message.include?("Tool execution")
      chat.messages.create!(
        role: 'system',
        content: "Tool error: #{e.message}"
      )
      retry
    else
      raise
    end

  ensure
    flush_stream_buffer(force: true)
    @ai_message&.update!(streaming: false) if @ai_message&.streaming?
  end

  # ... rest of existing streaming methods ...
end
```

### Step 5: Simple UI Updates

- [ ] Add checkbox to chat settings

```svelte
<!-- app/frontend/pages/chats/show.svelte -->
<script>
  import { router } from '@inertiajs/svelte';
  import { Globe, Check } from 'phosphor-svelte';

  // ... existing imports and props ...

  function toggleWebAccess() {
    router.patch(`/accounts/${account.id}/chats/${chat.id}`, {
      chat: { can_fetch_urls: !chat.can_fetch_urls }
    }, {
      preserveScroll: true
    });
  }
</script>

<!-- Add after chat header, before messages -->
<div class="border-b border-base-300 px-4 py-2">
  <label class="flex items-center gap-2 cursor-pointer">
    <input
      type="checkbox"
      checked={chat.can_fetch_urls}
      onchange={toggleWebAccess}
      class="checkbox checkbox-sm"
    />
    <Globe size={16} />
    <span class="text-sm">Allow web access</span>
  </label>
</div>

<!-- In message display, show tool usage -->
{#if message.tools_used?.length > 0}
  <div class="flex gap-2 mt-1 text-xs text-base-content/60">
    <Globe size={14} />
    <span>Used {message.tools_used.join(', ')}</span>
  </div>
{/if}
```

- [ ] Update controller to handle the update

```ruby
# app/controllers/chats_controller.rb
class ChatsController < ApplicationController
  # ... existing code ...

  def update
    @chat = current_account.chats.find(params[:id])
    @chat.update!(chat_params)

    # Broadcast refresh so UI updates everywhere
    @chat.broadcast_refresh
    head :ok
  end

  private

  def chat_params
    params.require(:chat).permit(:title, :can_fetch_urls)
  end
end
```

### Step 6: Simple Tests

- [ ] Test the tool directly

```ruby
# test/tools/web_fetch_tool_test.rb
require "test_helper"

class WebFetchToolTest < ActiveSupport::TestCase
  def setup
    @tool = WebFetchTool.new
  end

  test "fetches content from URL" do
    # Stub Net::HTTP to avoid real network calls
    response = Net::HTTPSuccess.new('1.1', '200', 'OK')
    response.stubs(:body).returns('<html><body>Hello World</body></html>')

    Net::HTTP.stubs(:start).yields(stub(request: response))

    result = @tool.execute(url: "https://example.com")

    assert_equal "Hello World", result[:content]
    assert_equal "https://example.com", result[:url]
  end

  test "handles invalid URLs" do
    result = @tool.execute(url: "not-a-url")
    assert result[:error].include?("Invalid URL")
  end

  test "handles HTTP errors" do
    response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
    Net::HTTP.stubs(:start).yields(stub(request: response))

    result = @tool.execute(url: "https://example.com/missing")
    assert result[:error].include?("404")
  end
end
```

- [ ] Test the chat model

```ruby
# test/models/chat_test.rb
class ChatTest < ActiveSupport::TestCase
  test "available_tools returns empty when web fetch disabled" do
    chat = chats(:one)
    chat.update!(can_fetch_urls: false)

    assert_empty chat.available_tools
  end

  test "available_tools includes WebFetchTool when enabled" do
    chat = chats(:one)
    chat.update!(can_fetch_urls: true)

    assert_includes chat.available_tools, WebFetchTool
  end
end
```

## That's It

No framework. No abstractions. No JSONB. No metaprogramming. No shell commands.

Just:
1. A boolean column
2. A tool class that uses Ruby's Net::HTTP
3. A checkbox in the UI
4. A simple array to track what was used

## Rails-Worthiness Assessment

✅ **Simple** - Could explain this to a junior developer in 5 minutes
✅ **Obvious** - Any Rails developer knows exactly what this does
✅ **No abstractions** - No base classes for a single tool
✅ **Rails conventions** - Fat models, RESTful controllers
✅ **Ruby stdlib** - Net::HTTP instead of shelling out to curl
✅ **Database simplicity** - Boolean column, not JSONB
✅ **Clear flow** - No callback soup, straightforward execution

## Future (When We Actually Need It)

If we add a second tool:
1. Add another boolean column (e.g., `can_read_files`)
2. Create another tool class
3. Add it to `available_tools` method
4. That's it

When we have 5+ tools and see real patterns, THEN we might extract something common. Not before.

The plan is ready for implementation.