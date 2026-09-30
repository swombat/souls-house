# Final Implementation Plan: Web Fetch Tool for Chats

## Executive Summary

Add web fetching capability to chats through a single boolean flag, one tool class, and minimal UI changes. This implementation follows Rails conventions rigorously - no abstractions, no complexity, just the simplest working solution.

## Architecture Overview

### Core Components
1. Boolean column `can_fetch_urls` on chats table
2. Single `WebFetchTool` class using Ruby's Net::HTTP
3. Checkbox in chat UI to toggle web access
4. Visual indicators when tools are used

### Rails Philosophy Applied
- **No premature abstractions** - One tool doesn't need a framework
- **Convention over configuration** - Boolean column, not JSONB
- **Ruby stdlib over external deps** - Net::HTTP, not curl
- **Fat models, skinny controllers** - Logic in Chat model
- **Clear over clever** - Explicit, obvious code

## Implementation Steps

### Step 1: Database Migration

- [ ] Add boolean flag for web fetch capability

```ruby
# db/migrate/[timestamp]_add_can_fetch_urls_to_chats.rb
class AddCanFetchUrlsToChats < ActiveRecord::Migration[8.0]
  def change
    add_column :chats, :can_fetch_urls, :boolean, default: false, null: false
    add_index :chats, :can_fetch_urls
  end
end
```

### Step 2: Update Chat Model

- [ ] Add tool configuration method to Chat

```ruby
# app/models/chat.rb
class Chat < ApplicationRecord
  # ... existing code ...

  # Add to json_attributes
  json_attributes :title, :model_id, :model_name, :updated_at_formatted,
                  :message_count, :can_fetch_urls

  # Configure tools for RubyLLM based on settings
  def available_tools
    return [] unless can_fetch_urls?
    [WebFetchTool]
  end
end
```

### Step 3: Create Web Fetch Tool

- [ ] Implement the tool using Ruby stdlib

```ruby
# app/tools/web_fetch_tool.rb
class WebFetchTool < RubyLLM::Tool
  description "Fetch and read content from a web page"

  param :url, type: 'string', description: 'The URL to fetch', required: true

  def execute(url:)
    require 'net/http'
    require 'uri'

    uri = URI.parse(url)

    # Basic validation
    unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return { error: "Invalid URL: must be http or https" }
    end

    # Fetch with reasonable timeouts
    response = Net::HTTP.start(uri.host, uri.port,
                              use_ssl: uri.scheme == 'https',
                              open_timeout: 5,
                              read_timeout: 10) do |http|
      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = 'HelixKit/1.0'
      http.request(request)
    end

    if response.is_a?(Net::HTTPSuccess)
      # Strip HTML tags and truncate for LLM context limits
      content = ActionView::Base.full_sanitizer.sanitize(response.body)
      content = content.strip.first(5000)

      {
        content: content,
        url: url,
        fetched_at: Time.current.iso8601
      }
    elsif response.is_a?(Net::HTTPRedirection)
      # Handle redirects transparently
      {
        redirect: response['location'],
        original_url: url
      }
    else
      {
        error: "HTTP #{response.code}: #{response.message}",
        url: url
      }
    end

  rescue => e
    # Let the LLM handle error messaging to user
    { error: e.message, url: url }
  end
end
```

### Step 4: Track Tool Usage

- [ ] Add simple array column to messages

```ruby
# db/migrate/[timestamp]_add_tools_used_to_messages.rb
class AddToolsUsedToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :tools_used, :text, array: true, default: []
    add_index :messages, :tools_used, using: :gin
  end
end
```

- [ ] Update Message model

```ruby
# app/models/message.rb
class Message < ApplicationRecord
  # ... existing code ...

  # Add to json_attributes
  json_attributes :role, :content, :user_name, :user_avatar_url, :completed,
                  :created_at_formatted, :created_at_hour, :streaming,
                  :files_json, :content_html, :tools_used

  # Simple helper for checking tool usage
  def used_tools?
    tools_used.present? && tools_used.any?
  end
end
```

### Step 5: Wire Up AI Response Job

- [ ] Configure tools and track usage

```ruby
# app/jobs/ai_response_job.rb
class AiResponseJob < ApplicationJob
  def perform(chat)
    @chat = chat
    @ai_message = nil
    @stream_buffer = +""
    @tools_used = []

    # Configure available tools from chat settings
    chat.tools = chat.available_tools if chat.respond_to?(:available_tools)

    # Track message creation
    chat.on_new_message do
      @ai_message = chat.messages.order(:created_at).last
      @ai_message.update!(streaming: true) if @ai_message
    end

    # Track tool invocations
    chat.on_tool_call do |tool_name, params, result|
      @tools_used << tool_name.to_s.underscore.humanize
      Rails.logger.info "Tool invoked: #{tool_name} with params: #{params}"
    end

    # Finalize message with tool usage info
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

    # Stream content chunks as before
    chat.complete do |chunk|
      next unless chunk.content && @ai_message
      enqueue_stream_chunk(chunk.content)
    end

  rescue => e
    Rails.logger.error "AI Response error: #{e.message}"
    raise
  ensure
    flush_stream_buffer(force: true)
    @ai_message&.update!(streaming: false) if @ai_message&.streaming?
  end

  # ... existing streaming methods remain unchanged ...
end
```

### Step 6: Add UI Controls

- [ ] Update controller to handle settings changes

```ruby
# app/controllers/chats_controller.rb
class ChatsController < ApplicationController
  # ... existing code ...

  def update
    @chat = current_account.chats.find(params[:id])

    if @chat.update(chat_params)
      @chat.broadcast_refresh
      head :ok
    else
      render json: { errors: @chat.errors }, status: :unprocessable_entity
    end
  end

  private

  def chat_params
    params.require(:chat).permit(:title, :model_id, :can_fetch_urls)
  end
end
```

- [ ] Add route for chat updates

```ruby
# config/routes.rb
# Within the accounts resources block:
resources :chats do
  resources :messages, only: :create
end
# The update action is already included via resources :chats
```

- [ ] Add toggle to chat interface

```svelte
<!-- app/frontend/pages/chats/show.svelte -->
<script>
  import { router } from '@inertiajs/svelte';
  import { Globe } from 'phosphor-svelte';

  // ... existing imports and props ...

  function toggleWebAccess() {
    router.patch(`/accounts/${account.id}/chats/${chat.id}`, {
      chat: { can_fetch_urls: !chat.can_fetch_urls }
    }, {
      preserveScroll: true,
      preserveState: true
    });
  }
</script>

<!-- Add settings bar after chat header -->
{#if chat}
  <div class="border-b border-base-300 px-4 py-2 flex items-center justify-between">
    <label class="flex items-center gap-2 cursor-pointer hover:opacity-80">
      <input
        type="checkbox"
        checked={chat.can_fetch_urls}
        onchange={toggleWebAccess}
        class="checkbox checkbox-sm checkbox-primary"
      />
      <Globe size={16} class="text-base-content/70" />
      <span class="text-sm text-base-content/70">Allow web access</span>
    </label>
  </div>
{/if}

<!-- In message component, show tool usage indicator -->
{#if message.tools_used?.length > 0}
  <div class="flex items-center gap-2 mt-2 text-xs text-base-content/50">
    <Globe size={14} />
    <span>Used: {message.tools_used.join(', ')}</span>
  </div>
{/if}
```

### Step 7: Write Tests

- [ ] Test the tool directly

```ruby
# test/tools/web_fetch_tool_test.rb
require "test_helper"

class WebFetchToolTest < ActiveSupport::TestCase
  def setup
    @tool = WebFetchTool.new
  end

  test "fetches content from valid URL" do
    # Stub HTTP response
    response = Net::HTTPSuccess.new('1.1', '200', 'OK')
    response.stubs(:body).returns('<html><body>Hello World</body></html>')

    Net::HTTP.stubs(:start).yields(stub(request: response))

    result = @tool.execute(url: "https://example.com")

    assert_equal "Hello World", result[:content]
    assert_equal "https://example.com", result[:url]
    assert result[:fetched_at].present?
  end

  test "rejects invalid URLs gracefully" do
    result = @tool.execute(url: "not-a-url")

    assert result[:error].present?
    assert_match /Invalid URL/, result[:error]
  end

  test "handles HTTP errors properly" do
    response = Net::HTTPNotFound.new('1.1', '404', 'Not Found')
    Net::HTTP.stubs(:start).yields(stub(request: response))

    result = @tool.execute(url: "https://example.com/missing")

    assert_match /404/, result[:error]
  end

  test "handles redirects" do
    response = Net::HTTPRedirection.new('1.1', '301', 'Moved')
    response.stubs(:[]).with('location').returns('https://new.example.com')
    Net::HTTP.stubs(:start).yields(stub(request: response))

    result = @tool.execute(url: "https://old.example.com")

    assert_equal "https://new.example.com", result[:redirect]
    assert_equal "https://old.example.com", result[:original_url]
  end
end
```

- [ ] Test chat model configuration

```ruby
# test/models/chat_test.rb
class ChatTest < ActiveSupport::TestCase
  test "returns empty tools when web fetch disabled" do
    chat = chats(:basic)
    chat.update!(can_fetch_urls: false)

    assert_empty chat.available_tools
  end

  test "includes WebFetchTool when enabled" do
    chat = chats(:basic)
    chat.update!(can_fetch_urls: true)

    assert_includes chat.available_tools, WebFetchTool
  end

  test "can_fetch_urls defaults to false" do
    chat = Chat.new
    assert_equal false, chat.can_fetch_urls
  end
end
```

- [ ] Test message tool tracking

```ruby
# test/models/message_test.rb
class MessageTest < ActiveSupport::TestCase
  test "tracks tools used" do
    message = messages(:assistant_reply)
    message.update!(tools_used: ["Web fetch"])

    assert message.used_tools?
    assert_includes message.tools_used, "Web fetch"
  end

  test "used_tools? returns false when empty" do
    message = messages(:user_question)

    assert_not message.used_tools?
  end
end
```

## Testing Strategy

### Manual Testing Checklist
- [ ] Toggle web access checkbox updates database
- [ ] Tool executes when enabled and URL mentioned
- [ ] Tool doesn't execute when disabled
- [ ] Error messages from tool appear in chat
- [ ] Tool usage indicator shows in UI
- [ ] Multiple tool invocations tracked correctly
- [ ] Chat continues after tool errors

### Edge Cases to Test
- [ ] Invalid URLs (malformed, non-HTTP)
- [ ] Timeouts on slow sites
- [ ] Large response bodies (truncation)
- [ ] HTML stripping works correctly
- [ ] Redirect handling
- [ ] Connection failures

## Production Considerations

### Security
- Timeouts prevent hanging requests
- User-Agent identifies requests
- HTML sanitization prevents XSS
- No arbitrary code execution
- Rate limiting can be added if needed

### Performance
- 5-second open timeout
- 10-second read timeout
- Content truncated to 5000 chars
- GIN index on tools_used array
- Minimal database overhead

### Monitoring
- Rails logs track tool invocations
- Errors logged with full context
- Tool usage visible in messages

## Future Extensions (When Actually Needed)

If we add a second tool:
1. Add another boolean (e.g., `can_execute_code`)
2. Create another tool class
3. Add to `available_tools` conditionally
4. No refactoring needed yet

After 5+ tools with clear patterns:
- Consider extracting common timeout behavior
- Maybe create a tools concern for models
- Only if patterns are obvious and repeated

## Rails-Worthiness Checklist

✅ **Simple** - One boolean, one class, one method
✅ **Obvious** - Any developer understands in minutes
✅ **No abstractions** - No base classes or frameworks
✅ **Rails conventions** - RESTful, fat models, AR patterns
✅ **Ruby stdlib** - Net::HTTP over external dependencies
✅ **Clear database** - Boolean column with index
✅ **Testable** - Simple unit tests, no integration complexity
✅ **Maintainable** - Changes are localized and obvious

## Implementation Order

1. **Database changes first** - Run migrations
2. **Model updates** - Add methods and attributes
3. **Tool class** - Create and test in isolation
4. **Job integration** - Wire up tool usage
5. **UI last** - Add controls and indicators
6. **Test everything** - Unit and manual testing

The plan is ready for immediate implementation.