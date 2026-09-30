# Tool Grouping Implementation Plan

## Executive Summary

This plan consolidates multiple similar tools into polymorphic tools to reduce tool count and context bloat. Two new polymorphic tools will replace four existing tools:

1. **PromptManagerTool** replaces `ViewSystemPromptTool` and `UpdateSystemPromptTool`
2. **WebTool** replaces `WebSearchTool` and `WebFetchTool`

The key design constraint is stability: adding new prompt types or web actions should only require adding enum values, not new tools. This follows the principle that tool schemas should remain stable as the application grows.

## Architecture Overview

### The Polymorphic Tool Pattern

Instead of:
```
view_system_prompt     → ViewSystemPromptTool
update_system_prompt   → UpdateSystemPromptTool
web_search            → WebSearchTool
web_fetch             → WebFetchTool
```

We consolidate to:
```
prompt_manager(action, prompt_type, content?)  → PromptManagerTool
web(action, query_or_url)                      → WebTool
```

### Design Principles

1. **Stable schemas** - New capabilities = new enum values, not new tools
2. **Self-correcting errors** - Return `allowed_actions` / `allowed_prompt_types` on validation failures
3. **Consistent result shapes** - Results include `type` field for branching
4. **Preserve existing behavior** - All current functionality remains intact

---

## Part 1: PromptManagerTool

### Schema Definition

```ruby
class PromptManagerTool < RubyLLM::Tool

  PROMPT_TYPES = {
    "system" => :system_prompt,
    "conversation_consolidation" => :reflection_prompt,
    "memory_management" => :memory_reflection_prompt,
    "name" => :name
  }.freeze

  ACTIONS = %w[view update].freeze

  description "View or update your prompts and name. prompt_type: system, conversation_consolidation, memory_management, or name. action: view or update."

  param :action, type: :string,
        desc: "Either 'view' or 'update'",
        required: true

  param :prompt_type, type: :string,
        desc: "One of: system, conversation_consolidation, memory_management, name",
        required: true

  param :content, type: :string,
        desc: "New value (required for update action)",
        required: false
```

### Behavior Matrix

| Action | prompt_type | content | Result |
|--------|-------------|---------|--------|
| view | system | - | Returns `system_prompt` value |
| view | conversation_consolidation | - | Returns `reflection_prompt` value |
| view | memory_management | - | Returns `memory_reflection_prompt` value |
| view | name | - | Returns `name` value |
| update | system | required | Updates `system_prompt` |
| update | conversation_consolidation | required | Updates `reflection_prompt` |
| update | memory_management | required | Updates `memory_reflection_prompt` |
| update | name | required | Updates `name` |

### Response Schemas

#### View Success
```ruby
{
  type: "view_result",
  prompt_type: "system",
  value: "You are a helpful assistant...",
  agent_name: "Sage"
}
```

#### Update Success
```ruby
{
  type: "update_result",
  prompt_type: "system",
  success: true,
  new_value: "You are now a coding expert...",
  agent_name: "Sage"
}
```

#### Validation Error
```ruby
{
  error: "Invalid prompt_type 'foo'",
  allowed_prompt_types: ["system", "conversation_consolidation", "memory_management", "name"],
  allowed_actions: ["view", "update"]
}
```

### Implementation

```ruby
class PromptManagerTool < RubyLLM::Tool

  PROMPT_TYPES = {
    "system" => :system_prompt,
    "conversation_consolidation" => :reflection_prompt,
    "memory_management" => :memory_reflection_prompt,
    "name" => :name
  }.freeze

  ACTIONS = %w[view update].freeze

  description "View or update your prompts and name. prompt_type: system, conversation_consolidation, memory_management, or name. action: view or update."

  param :action, type: :string,
        desc: "Either 'view' or 'update'",
        required: true

  param :prompt_type, type: :string,
        desc: "One of: system, conversation_consolidation, memory_management, name",
        required: true

  param :content, type: :string,
        desc: "New value (required for update action)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(action:, prompt_type:, content: nil)
    return context_error unless @chat&.group_chat?
    return context_error("No current agent context") unless @current_agent
    return validation_error("Invalid action '#{action}'") unless ACTIONS.include?(action)
    return validation_error("Invalid prompt_type '#{prompt_type}'") unless PROMPT_TYPES.key?(prompt_type)
    return validation_error("content is required for update action") if action == "update" && content.blank?

    case action
    when "view" then view_prompt(prompt_type)
    when "update" then update_prompt(prompt_type, content)
    end
  end

  private

  def view_prompt(prompt_type)
    attribute = PROMPT_TYPES[prompt_type]
    value = @current_agent.send(attribute)

    {
      type: "view_result",
      prompt_type: prompt_type,
      value: value.presence || "(not set)",
      agent_name: @current_agent.name
    }
  end

  def update_prompt(prompt_type, content)
    attribute = PROMPT_TYPES[prompt_type]

    if @current_agent.update(attribute => content)
      {
        type: "update_result",
        prompt_type: prompt_type,
        success: true,
        new_value: @current_agent.send(attribute),
        agent_name: @current_agent.name
      }
    else
      {
        error: "Failed to update: #{@current_agent.errors.full_messages.join(', ')}",
        prompt_type: prompt_type
      }
    end
  end

  def context_error(message = "This tool only works in group conversations")
    { error: message }
  end

  def validation_error(message)
    {
      error: message,
      allowed_prompt_types: PROMPT_TYPES.keys,
      allowed_actions: ACTIONS
    }
  end

end
```

---

## Part 2: WebTool

### Schema Definition

```ruby
class WebTool < RubyLLM::Tool

  ACTIONS = %w[search fetch].freeze

  description "Search the web or fetch a page. action: search (query) or fetch (URL). Limited to #{MAX_SEARCHES_PER_SESSION} searches per response."

  param :action, type: :string,
        desc: "Either 'search' or 'fetch'",
        required: true

  param :query_or_url, type: :string,
        desc: "Search query for 'search' action, or URL for 'fetch' action",
        required: true
```

### Behavior Matrix

| Action | query_or_url | Result |
|--------|--------------|--------|
| search | "ruby on rails" | Search results array |
| fetch | "https://example.com" | Page content |

### Response Schemas

#### Search Result
```ruby
{
  type: "search_results",
  query: "ruby on rails",
  results: [
    { url: "...", title: "...", snippet: "..." }
  ],
  total_results: 1200
}
```

#### Fetch Result
```ruby
{
  type: "fetched_page",
  url: "https://example.com",
  content: "Page content...",
  fetched_at: "2024-12-30T10:00:00Z"
}
```

#### Fetch Redirect
```ruby
{
  type: "redirect",
  original_url: "http://example.com",
  redirect_url: "https://example.com/new-path"
}
```

#### Error Response
```ruby
{
  type: "error",
  error: "Search limit reached",
  query_or_url: "test query",
  allowed_actions: ["search", "fetch"]
}
```

### Implementation

```ruby
require "net/http"
require "json"
require "uri"

class WebTool < RubyLLM::Tool

  ACTIONS = %w[search fetch].freeze
  RESULT_LIMIT = 10
  MAX_SEARCHES_PER_SESSION = 10
  OPEN_TIMEOUT = 10
  READ_TIMEOUT = 15

  description "Search the web or fetch a page. action: search (query) or fetch (URL). Limited to #{MAX_SEARCHES_PER_SESSION} searches per response."

  param :action, type: :string,
        desc: "Either 'search' or 'fetch'",
        required: true

  param :query_or_url, type: :string,
        desc: "Search query for 'search' action, or URL for 'fetch' action",
        required: true

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
    @search_count = 0
  end

  def execute(action:, query_or_url:)
    return validation_error("Invalid action '#{action}'", query_or_url) unless ACTIONS.include?(action)

    case action
    when "search" then search(query_or_url)
    when "fetch" then fetch(query_or_url)
    end
  end

  private

  # === Search Logic ===

  def search(query)
    @search_count += 1

    if @search_count > MAX_SEARCHES_PER_SESSION
      return search_error("Search limit reached (#{MAX_SEARCHES_PER_SESSION} searches per response)", query)
    end

    response = fetch_search_results(query)
    return search_error("HTTP #{response.code}: #{response.message}", query) unless response.is_a?(Net::HTTPSuccess)

    parse_search_results(response.body, query)
  rescue JSON::ParserError
    search_error("Invalid response from search service", query)
  rescue => e
    search_error(e.message, query)
  end

  def fetch_search_results(query)
    uri = build_search_uri(query)

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "HelixKit/1.0"
      http.request(request)
    end
  end

  def build_search_uri(query)
    uri = URI("#{searxng_instance_url}/search")
    uri.query = URI.encode_www_form(q: query, format: "json")
    uri
  end

  def parse_search_results(body, query)
    data = JSON.parse(body)

    {
      type: "search_results",
      query: query,
      results: data["results"].first(RESULT_LIMIT).map { |r| format_search_result(r) },
      total_results: data["number_of_results"]
    }
  end

  def format_search_result(result)
    {
      url: result["url"],
      title: result["title"],
      snippet: result["content"]
    }
  end

  def search_error(message, query)
    { type: "error", error: message, query_or_url: query }
  end

  def searxng_instance_url
    Rails.application.credentials.dig(:searxng, :instance_url) ||
      raise("SearXNG URL not configured. Add searxng.instance_url to Rails credentials.")
  end

  # === Fetch Logic ===

  def fetch(url)
    uri = URI.parse(url)

    unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return fetch_error("Invalid URL: must be http or https", url)
    end

    response = Net::HTTP.start(uri.host, uri.port,
                               use_ssl: uri.scheme == "https",
                               open_timeout: 5,
                               read_timeout: 10) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "HelixKit/1.0"
      http.request(request)
    end

    handle_fetch_response(response, url)
  rescue => e
    fetch_error(e.message, url)
  end

  def handle_fetch_response(response, url)
    if response.is_a?(Net::HTTPSuccess)
      content = ActionView::Base.full_sanitizer.sanitize(response.body)
      content = content.strip.first(40000)

      {
        type: "fetched_page",
        url: url,
        content: content,
        fetched_at: Time.current.iso8601
      }
    elsif response.is_a?(Net::HTTPRedirection)
      {
        type: "redirect",
        original_url: url,
        redirect_url: response["location"]
      }
    else
      fetch_error("HTTP #{response.code}: #{response.message}", url)
    end
  end

  def fetch_error(message, url)
    { type: "error", error: message, query_or_url: url }
  end

  def validation_error(message, query_or_url)
    {
      type: "error",
      error: message,
      query_or_url: query_or_url,
      allowed_actions: ACTIONS
    }
  end

end
```

---

## Implementation Checklist

### Phase 1: Create New Tools

- [ ] Create `/app/tools/prompt_manager_tool.rb`
- [ ] Create `/app/tools/web_tool.rb`

### Phase 2: Create Tests

- [ ] Create `/test/tools/prompt_manager_tool_test.rb`
  - [ ] Test view action for all prompt types
  - [ ] Test update action for all prompt types
  - [ ] Test validation errors return `allowed_prompt_types` and `allowed_actions`
  - [ ] Test context restrictions (group chat only)
  - [ ] Test missing content for update action

- [ ] Create `/test/tools/web_tool_test.rb`
  - [ ] Test search action (migrate tests from `WebSearchToolTest`)
  - [ ] Test fetch action (migrate tests from `WebFetchToolTest`)
  - [ ] Test validation errors return `allowed_actions`
  - [ ] Test rate limiting for searches
  - [ ] Test consistent `type` field in all responses

### Phase 3: Update Agent Configuration

- [ ] Update any agent records that have old tool names in `enabled_tools`
  - `ViewSystemPromptTool` -> `PromptManagerTool`
  - `UpdateSystemPromptTool` -> `PromptManagerTool`
  - `WebSearchTool` -> `WebTool`
  - `WebFetchTool` -> `WebTool`
- [ ] This can be done via a data migration or rake task

### Phase 4: Remove Old Tools

- [ ] Delete `/app/tools/view_system_prompt_tool.rb`
- [ ] Delete `/app/tools/update_system_prompt_tool.rb`
- [ ] Delete `/app/tools/web_search_tool.rb`
- [ ] Delete `/app/tools/web_fetch_tool.rb`
- [ ] Delete `/test/tools/web_search_tool_test.rb`
- [ ] Delete `/test/tools/web_fetch_tool_test.rb`

### Phase 5: Documentation

- [ ] Create `/docs/polymorphic-tools.md` documenting:
  - The polymorphic tool pattern
  - How to extend tools with new actions/types
  - Best practices for tool design
- [ ] Update `/docs/overview.md` to reference the new documentation

### Phase 6: Final Verification

- [ ] Run full test suite: `rails test`
- [ ] Verify tools appear correctly in agent configuration UI
- [ ] Test both tools manually in a group chat

---

## Test Plan

### PromptManagerTool Tests

```ruby
require "test_helper"

class PromptManagerToolTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:one)
    @agent = agents(:one)
    @agent.update!(
      system_prompt: "Original system prompt",
      reflection_prompt: "Original reflection prompt",
      memory_reflection_prompt: "Original memory prompt"
    )
    @chat = chats(:group_chat)
    @tool = PromptManagerTool.new(chat: @chat, current_agent: @agent)
  end

  # View action tests

  test "view system prompt returns current value" do
    result = @tool.execute(action: "view", prompt_type: "system")

    assert_equal "view_result", result[:type]
    assert_equal "system", result[:prompt_type]
    assert_equal "Original system prompt", result[:value]
    assert_equal @agent.name, result[:agent_name]
  end

  test "view conversation_consolidation returns reflection_prompt" do
    result = @tool.execute(action: "view", prompt_type: "conversation_consolidation")

    assert_equal "view_result", result[:type]
    assert_equal "conversation_consolidation", result[:prompt_type]
    assert_equal "Original reflection prompt", result[:value]
  end

  test "view memory_management returns memory_reflection_prompt" do
    result = @tool.execute(action: "view", prompt_type: "memory_management")

    assert_equal "view_result", result[:type]
    assert_equal "memory_management", result[:prompt_type]
    assert_equal "Original memory prompt", result[:value]
  end

  test "view name returns agent name" do
    result = @tool.execute(action: "view", prompt_type: "name")

    assert_equal "view_result", result[:type]
    assert_equal "name", result[:prompt_type]
    assert_equal @agent.name, result[:value]
  end

  test "view returns '(not set)' for nil values" do
    @agent.update!(system_prompt: nil)
    result = @tool.execute(action: "view", prompt_type: "system")

    assert_equal "(not set)", result[:value]
  end

  # Update action tests

  test "update system prompt changes value" do
    result = @tool.execute(action: "update", prompt_type: "system", content: "New system prompt")

    assert_equal "update_result", result[:type]
    assert result[:success]
    assert_equal "New system prompt", result[:new_value]
    assert_equal "New system prompt", @agent.reload.system_prompt
  end

  test "update conversation_consolidation changes reflection_prompt" do
    result = @tool.execute(action: "update", prompt_type: "conversation_consolidation", content: "New reflection")

    assert result[:success]
    assert_equal "New reflection", @agent.reload.reflection_prompt
  end

  test "update memory_management changes memory_reflection_prompt" do
    result = @tool.execute(action: "update", prompt_type: "memory_management", content: "New memory prompt")

    assert result[:success]
    assert_equal "New memory prompt", @agent.reload.memory_reflection_prompt
  end

  test "update name changes agent name" do
    result = @tool.execute(action: "update", prompt_type: "name", content: "New Agent Name")

    assert result[:success]
    assert_equal "New Agent Name", @agent.reload.name
  end

  # Validation error tests

  test "invalid action returns error with allowed values" do
    result = @tool.execute(action: "delete", prompt_type: "system")

    assert_match(/Invalid action/, result[:error])
    assert_equal %w[view update], result[:allowed_actions]
    assert_equal PromptManagerTool::PROMPT_TYPES.keys, result[:allowed_prompt_types]
  end

  test "invalid prompt_type returns error with allowed values" do
    result = @tool.execute(action: "view", prompt_type: "invalid")

    assert_match(/Invalid prompt_type/, result[:error])
    assert_equal %w[view update], result[:allowed_actions]
    assert_equal PromptManagerTool::PROMPT_TYPES.keys, result[:allowed_prompt_types]
  end

  test "update without content returns error" do
    result = @tool.execute(action: "update", prompt_type: "system")

    assert_match(/content is required/, result[:error])
  end

  # Context restriction tests

  test "returns error without group chat context" do
    tool = PromptManagerTool.new(chat: nil, current_agent: @agent)
    result = tool.execute(action: "view", prompt_type: "system")

    assert_match(/group conversations/, result[:error])
  end

  test "returns error without agent context" do
    tool = PromptManagerTool.new(chat: @chat, current_agent: nil)
    result = tool.execute(action: "view", prompt_type: "system")

    assert_match(/No current agent/, result[:error])
  end

end
```

### WebTool Tests

```ruby
require "test_helper"
require "webmock/minitest"

class WebToolTest < ActiveSupport::TestCase

  setup do
    @tool = WebTool.new
    @tool.define_singleton_method(:searxng_instance_url) { "https://searxng.example.com" }
  end

  # Search action tests

  test "search returns results with type field" do
    stub_searxng_success

    result = @tool.execute(action: "search", query_or_url: "ruby on rails")

    assert_equal "search_results", result[:type]
    assert_equal "ruby on rails", result[:query]
    assert_equal 2, result[:results].length
  end

  test "search limits results to maximum" do
    stub_searxng_with_many_results(15)

    result = @tool.execute(action: "search", query_or_url: "test")

    assert_equal 10, result[:results].length
  end

  test "search enforces rate limit" do
    stub_searxng_success

    WebTool::MAX_SEARCHES_PER_SESSION.times do |i|
      result = @tool.execute(action: "search", query_or_url: "query #{i}")
      assert_nil result[:error]
    end

    result = @tool.execute(action: "search", query_or_url: "one too many")
    assert_equal "error", result[:type]
    assert_match(/Search limit reached/, result[:error])
  end

  test "search error includes type field" do
    stub_request(:get, /searxng/).to_return(status: 500)

    result = @tool.execute(action: "search", query_or_url: "test")

    assert_equal "error", result[:type]
    assert_match(/500/, result[:error])
  end

  # Fetch action tests

  test "fetch returns content with type field" do
    stub_request(:get, "https://example.com/")
      .to_return(status: 200, body: "<html><body>Hello World</body></html>")

    result = @tool.execute(action: "fetch", query_or_url: "https://example.com")

    assert_equal "fetched_page", result[:type]
    assert_equal "https://example.com", result[:url]
    assert_match(/Hello World/, result[:content])
    assert result[:fetched_at].present?
  end

  test "fetch handles redirects" do
    stub_request(:get, "http://example.com/")
      .to_return(status: 301, headers: { "Location" => "https://example.com/new" })

    result = @tool.execute(action: "fetch", query_or_url: "http://example.com")

    assert_equal "redirect", result[:type]
    assert_equal "http://example.com", result[:original_url]
    assert_equal "https://example.com/new", result[:redirect_url]
  end

  test "fetch rejects non-HTTP URLs" do
    result = @tool.execute(action: "fetch", query_or_url: "ftp://example.com")

    assert_equal "error", result[:type]
    assert_match(/Invalid URL/, result[:error])
  end

  # Validation tests

  test "invalid action returns error with allowed values" do
    result = @tool.execute(action: "crawl", query_or_url: "test")

    assert_equal "error", result[:type]
    assert_match(/Invalid action/, result[:error])
    assert_equal %w[search fetch], result[:allowed_actions]
  end

  private

  def stub_searxng_success
    stub_request(:get, /searxng/)
      .to_return(status: 200, body: searxng_response(2).to_json,
                 headers: { "Content-Type" => "application/json" })
  end

  def stub_searxng_with_many_results(count)
    stub_request(:get, /searxng/)
      .to_return(status: 200, body: searxng_response(count).to_json)
  end

  def searxng_response(count)
    {
      query: "ruby on rails",
      number_of_results: count * 100,
      results: Array.new(count) { |i|
        { url: "https://example#{i}.com", title: "Result #{i}", content: "Content #{i}" }
      }
    }
  end

end
```

---

## Data Migration

A rake task to update existing agent configurations:

```ruby
# lib/tasks/migrate_tools.rake
namespace :tools do
  desc "Migrate old tool names to new polymorphic tools"
  task migrate: :environment do
    mappings = {
      "ViewSystemPromptTool" => "PromptManagerTool",
      "UpdateSystemPromptTool" => "PromptManagerTool",
      "WebSearchTool" => "WebTool",
      "WebFetchTool" => "WebTool"
    }

    Agent.find_each do |agent|
      next if agent.enabled_tools.blank?

      new_tools = agent.enabled_tools.map { |t| mappings[t] || t }.uniq

      if new_tools != agent.enabled_tools
        puts "Updating agent #{agent.id} (#{agent.name}): #{agent.enabled_tools} -> #{new_tools}"
        agent.update!(enabled_tools: new_tools)
      end
    end

    puts "Migration complete!"
  end
end
```

---

## Documentation Template

### /docs/polymorphic-tools.md

```markdown
# Polymorphic Tools

This document describes the polymorphic tool pattern used in Helix Kit for consolidating related tool functionality.

## Philosophy

Instead of creating separate tools for each action (view_x, update_x, search, fetch), we consolidate related functionality into single polymorphic tools with action parameters. This:

1. **Reduces tool count** - Fewer tools means less context bloat for LLMs
2. **Stabilizes schemas** - New capabilities are enum values, not new tools
3. **Enables self-correction** - Validation errors include allowed values

## Current Polymorphic Tools

### PromptManagerTool

Manages agent prompts and name.

**Parameters:**
- `action`: `view` or `update`
- `prompt_type`: `system`, `conversation_consolidation`, `memory_management`, or `name`
- `content`: Required for update action

**Example usage:**
\`\`\`
prompt_manager(action: "view", prompt_type: "system")
prompt_manager(action: "update", prompt_type: "name", content: "New Name")
\`\`\`

### WebTool

Web search and page fetching.

**Parameters:**
- `action`: `search` or `fetch`
- `query_or_url`: Search query or URL depending on action

**Example usage:**
\`\`\`
web(action: "search", query_or_url: "ruby on rails tutorial")
web(action: "fetch", query_or_url: "https://rubyonrails.org")
\`\`\`

## Adding New Capabilities

### Adding a New Prompt Type

1. Add mapping to `PROMPT_TYPES` in `PromptManagerTool`
2. Ensure the corresponding attribute exists on the Agent model
3. Add tests for the new prompt type

### Adding a New Web Action

1. Add action to `ACTIONS` in `WebTool`
2. Add handler method (e.g., `extract(url)`)
3. Add case branch in `execute`
4. Add tests for the new action

## Response Conventions

All polymorphic tools include a `type` field in responses:

- Success: `{ type: "view_result", ... }` or `{ type: "search_results", ... }`
- Error: `{ type: "error", error: "...", allowed_actions: [...] }`

This allows LLMs to reliably branch on response type.
```

---

## Edge Cases and Error Handling

### PromptManagerTool

1. **Nil prompt values**: Return "(not set)" for view, allow update to set value
2. **Validation failures**: Agent model validations bubble up with clear messages
3. **Name uniqueness**: The Agent model validates name uniqueness per account; errors are surfaced
4. **Content too long**: Model validations enforce length limits (50k for system_prompt, 10k for others)

### WebTool

1. **Rate limiting**: Searches after limit return error with clear message
2. **Network timeouts**: Caught and returned as error response
3. **Invalid URLs**: Validated before attempting fetch
4. **Large pages**: Content truncated to 40k characters
5. **Redirects**: Returned as separate response type for LLM to handle
6. **SearXNG config missing**: Clear error message with setup instructions

---

## Rollback Plan

If issues are discovered post-deployment:

1. Restore deleted tool files from git
2. Run inverse rake task to restore old tool names in agent configs
3. Remove new tool files

The git history preserves all original implementations.
