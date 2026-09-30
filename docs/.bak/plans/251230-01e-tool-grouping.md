# Tool Grouping Implementation Plan

## Executive Summary

This plan establishes domain-based tool consolidation as the architectural pattern for scaling to 50+ agent capabilities. Two consolidated tools replace four individual tools:

1. **SelfAuthoringTool** - Manages all agent configuration (prompts, name, future: model, settings)
2. **WebTool** - Handles all web operations (search, fetch, future: extract)

Each domain tool accepts `action` + domain-specific parameters, routes to focused private methods, and returns structured responses with type discrimination. Self-correcting errors include valid options so LLMs can retry without additional context.

---

## Architecture Overview

### The Scale Constraint

The core constraint is LLM capability at scale. With 50+ capabilities incoming:

| Approach | Tools at 50 capabilities | Context impact |
|----------|--------------------------|----------------|
| One tool per action | 50+ tools | Significant context bloat |
| Domain consolidation | 10-15 tools | Manageable context |

Domain consolidation wins.

### Design Principles

1. **Action as first parameter** - Every consolidated tool starts with `action:`
2. **Direct attribute names** - No translation layers. `system_prompt` in the API means `system_prompt` on the model
3. **Self-correcting errors** - Validation failures return `allowed_actions` and valid values
4. **Under 100 lines** - Consolidation must not create God classes
5. **Type-discriminated responses** - Every response includes `type:` for branching
6. **Null for unset values** - Return `nil` for unset values; null is unambiguous for LLMs

### Tool Lifecycle

Tool instances are created per response generation. Instance state like `@search_count` resets appropriately between agent turns. This is the intended behavior for rate limiting and other per-response concerns.

### Domain Tool Pattern

```ruby
class DomainTool < RubyLLM::Tool
  ACTIONS = %w[action_one action_two].freeze

  def execute(action:, **params)
    return validation_error(action) unless ACTIONS.include?(action)
    send("#{action}_action", **params)
  end

  private

  def action_one_action(**params)
    # Focused, testable, under 20 lines
  end
end
```

---

## Part 1: SelfAuthoringTool

### Why This Name

- `SelfAuthoringTool` accurately describes scope: agent configuration
- Manages prompts, name, and will extend to model selection, enabled tools, etc.
- Matches the domain pattern: `WebTool`, `MemoryTool`, `SelfAuthoringTool`

### Implementation

```ruby
class SelfAuthoringTool < RubyLLM::Tool

  ACTIONS = %w[view update].freeze

  FIELDS = %w[
    name
    system_prompt
    reflection_prompt
    memory_reflection_prompt
  ].freeze

  description "View or update your configuration. Actions: view, update. Fields: name, system_prompt, reflection_prompt, memory_reflection_prompt."

  param :action, type: :string,
        desc: "view or update",
        required: true

  param :field, type: :string,
        desc: "name, system_prompt, reflection_prompt, or memory_reflection_prompt",
        required: true

  param :value, type: :string,
        desc: "New value (required for update)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
  end

  def execute(action:, field:, value: nil)
    return context_error unless @chat&.group_chat? && @current_agent

    unless ACTIONS.include?(action)
      return validation_error("Invalid action '#{action}'")
    end

    unless FIELDS.include?(field)
      return validation_error("Invalid field '#{field}'")
    end

    send("#{action}_field", field, value)
  end

  private

  def view_field(field, _value)
    {
      type: "config",
      action: "view",
      field: field,
      value: @current_agent.public_send(field),
      agent: @current_agent.name
    }
  end

  def update_field(field, value)
    if value.blank?
      return validation_error("value required for update")
    end

    if @current_agent.update(field => value)
      {
        type: "config",
        action: "update",
        field: field,
        value: @current_agent.public_send(field),
        agent: @current_agent.name
      }
    else
      {
        type: "error",
        error: @current_agent.errors.full_messages.join(", "),
        field: field
      }
    end
  end

  def context_error
    { type: "error", error: "This tool only works in group conversations with an agent context" }
  end

  def validation_error(message)
    {
      type: "error",
      error: message,
      allowed_actions: ACTIONS,
      allowed_fields: FIELDS
    }
  end

end
```

**Line count: 68 lines.**

### Response Schema

```ruby
# View success (nil for unset values)
{ type: "config", action: "view", field: "system_prompt", value: "...", agent: "Sage" }
{ type: "config", action: "view", field: "system_prompt", value: nil, agent: "Sage" }

# Update success
{ type: "config", action: "update", field: "name", value: "NewName", agent: "NewName" }

# Validation error (self-correcting)
{ type: "error", error: "Invalid field 'foo'", allowed_actions: ["view", "update"], allowed_fields: ["name", "system_prompt", ...] }

# Context error
{ type: "error", error: "This tool only works in group conversations with an agent context" }

# Model validation error
{ type: "error", error: "Name has already been taken", field: "name" }
```

---

## Part 2: WebTool

### Parameter Design

Two separate optional parameters rather than `query_or_url`:

- `query` - always means search query
- `url` - always means URL to fetch

The tool validates which parameter is required for which action and returns self-correcting errors.

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

  description "Search the web or fetch a page. Use action 'search' with query, or 'fetch' with url."

  param :action, type: :string,
        desc: "search or fetch",
        required: true

  param :query, type: :string,
        desc: "Search query (required for search action)",
        required: false

  param :url, type: :string,
        desc: "URL to fetch (required for fetch action)",
        required: false

  def initialize(chat: nil, current_agent: nil)
    super()
    @chat = chat
    @current_agent = current_agent
    @search_count = 0
  end

  def execute(action:, query: nil, url: nil)
    unless ACTIONS.include?(action)
      return validation_error("Invalid action '#{action}'")
    end

    case action
    when "search" then search(query)
    when "fetch" then fetch(url)
    end
  end

  private

  def search(query)
    return param_error("search", "query") if query.blank?

    @search_count += 1
    if @search_count > MAX_SEARCHES_PER_SESSION
      return { type: "error", error: "Search limit reached (#{MAX_SEARCHES_PER_SESSION} per response)", query: query }
    end

    response = fetch_search_results(query)
    unless response.is_a?(Net::HTTPSuccess)
      return { type: "error", error: "HTTP #{response.code}: #{response.message}", query: query }
    end

    parse_search_results(response.body, query)
  rescue JSON::ParserError
    { type: "error", error: "Invalid response from search service", query: query }
  rescue => e
    { type: "error", error: e.message, query: query }
  end

  def fetch_search_results(query)
    uri = URI("#{searxng_instance_url}/search")
    uri.query = URI.encode_www_form(q: query, format: "json")

    Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "HelixKit/1.0"
      http.request(request)
    end
  end

  def parse_search_results(body, query)
    data = JSON.parse(body)
    {
      type: "search_results",
      query: query,
      results: data["results"].first(RESULT_LIMIT).map { |r|
        { url: r["url"], title: r["title"], snippet: r["content"] }
      },
      total_results: data["number_of_results"]
    }
  end

  def searxng_instance_url
    Rails.application.credentials.dig(:searxng, :instance_url) ||
      raise("SearXNG URL not configured")
  end

  def fetch(url)
    return param_error("fetch", "url") if url.blank?

    uri = URI.parse(url)
    unless uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
      return { type: "error", error: "Invalid URL: must be http or https", url: url }
    end

    response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                               open_timeout: 5, read_timeout: 10) do |http|
      request = Net::HTTP::Get.new(uri)
      request["User-Agent"] = "HelixKit/1.0"
      http.request(request)
    end

    handle_fetch_response(response, url)
  rescue => e
    { type: "error", error: e.message, url: url }
  end

  def handle_fetch_response(response, url)
    case response
    when Net::HTTPSuccess
      content = ActionView::Base.full_sanitizer.sanitize(response.body)
      { type: "fetched_page", url: url, content: content.strip.first(40000), fetched_at: Time.current.iso8601 }
    when Net::HTTPRedirection
      { type: "redirect", original_url: url, redirect_url: response["location"] }
    else
      { type: "error", error: "HTTP #{response.code}: #{response.message}", url: url }
    end
  end

  def validation_error(message)
    { type: "error", error: message, allowed_actions: ACTIONS }
  end

  def param_error(action, missing_param)
    {
      type: "error",
      error: "#{missing_param} is required for #{action} action",
      action: action,
      required_param: missing_param,
      allowed_actions: ACTIONS
    }
  end

end
```

**Line count: 98 lines.**

### Response Schema

```ruby
# Search success
{ type: "search_results", query: "rails 8", results: [...], total_results: 1200 }

# Fetch success
{ type: "fetched_page", url: "https://...", content: "...", fetched_at: "2024-12-30T..." }

# Redirect
{ type: "redirect", original_url: "http://...", redirect_url: "https://..." }

# Validation error (self-correcting)
{ type: "error", error: "Invalid action 'crawl'", allowed_actions: ["search", "fetch"] }

# Missing param error (self-correcting)
{ type: "error", error: "query is required for search action", action: "search", required_param: "query", allowed_actions: ["search", "fetch"] }
```

---

## Future Domain Tools

The pattern scales naturally:

```ruby
class MemoryTool < RubyLLM::Tool
  ACTIONS = %w[save recall search forget].freeze
  # ...
end

class TaskTool < RubyLLM::Tool
  ACTIONS = %w[create update complete list].freeze
  # ...
end
```

At 50 capabilities, this yields approximately 10 domain tools instead of 50 individual tools.

---

## Implementation Checklist

### Phase 1: Create New Tools

- [ ] Create `/app/tools/agent_config_tool.rb`
- [ ] Create `/app/tools/web_tool.rb`

### Phase 2: Tests

- [ ] Create `/test/tools/agent_config_tool_test.rb`
  - [ ] Test view action for all fields
  - [ ] Test update action for all fields
  - [ ] Test validation errors include allowed_actions and allowed_fields
  - [ ] Test context restrictions (group chat + agent required)
  - [ ] Test model validation errors surface correctly
  - [ ] Test nil field values return nil (not a string)

- [ ] Create `/test/tools/web_tool_test.rb`
  - [ ] Test search action with query
  - [ ] Test search rate limiting
  - [ ] Test fetch action with url
  - [ ] Test fetch redirects
  - [ ] Test invalid URL rejection
  - [ ] Test validation errors include allowed_actions
  - [ ] Test param errors include required_param

### Phase 3: Migration

- [ ] Create rake task to update agent `enabled_tools`:
  ```ruby
  # lib/tasks/tools.rake
  namespace :tools do
    desc "Migrate to consolidated tools"
    task consolidate: :environment do
      migrations = {
        "ViewSystemPromptTool" => "SelfAuthoringTool",
        "UpdateSystemPromptTool" => "SelfAuthoringTool",
        "WebSearchTool" => "WebTool",
        "WebFetchTool" => "WebTool"
      }

      Agent.find_each do |agent|
        next if agent.enabled_tools.blank?

        new_tools = agent.enabled_tools.map { |t| migrations[t] || t }.uniq
        agent.update!(enabled_tools: new_tools) if new_tools != agent.enabled_tools
      end
    end
  end
  ```

- [ ] Run migration: `rails tools:consolidate`

### Phase 4: Remove Old Tools

- [ ] Delete `/app/tools/view_system_prompt_tool.rb`
- [ ] Delete `/app/tools/update_system_prompt_tool.rb`
- [ ] Delete `/app/tools/web_search_tool.rb`
- [ ] Delete `/app/tools/web_fetch_tool.rb`

### Phase 5: Documentation

- [ ] Create `/docs/domain-tools.md` documenting:
  - The domain tool pattern
  - How to add new actions to existing tools
  - How to create new domain tools
  - Self-correcting error conventions
- [ ] Update `/docs/overview.md` to reference new documentation

### Phase 6: Verification

- [ ] Run full test suite: `rails test`
- [ ] Verify tools appear in agent configuration UI
- [ ] Manual test in group chat:
  - [ ] View each field
  - [ ] Update each field
  - [ ] Search the web
  - [ ] Fetch a page
  - [ ] Trigger validation errors, verify self-correction info

---

## Test Plan

### SelfAuthoringTool Tests

```ruby
require "test_helper"

class SelfAuthoringToolTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:one)
    @agent.update!(
      system_prompt: "Original system",
      reflection_prompt: "Original reflection",
      memory_reflection_prompt: "Original memory"
    )
    @chat = chats(:group_chat)
    @tool = SelfAuthoringTool.new(chat: @chat, current_agent: @agent)
  end

  test "view returns field value with type" do
    result = @tool.execute(action: "view", field: "system_prompt")

    assert_equal "config", result[:type]
    assert_equal "view", result[:action]
    assert_equal "system_prompt", result[:field]
    assert_equal "Original system", result[:value]
    assert_equal @agent.name, result[:agent]
  end

  test "view returns nil for unset values" do
    @agent.update!(system_prompt: nil)

    result = @tool.execute(action: "view", field: "system_prompt")

    assert_nil result[:value]
  end

  test "view works for all fields" do
    SelfAuthoringTool::FIELDS.each do |field|
      result = @tool.execute(action: "view", field: field)
      assert_equal "config", result[:type]
      assert_equal field, result[:field]
    end
  end

  test "update changes field value" do
    result = @tool.execute(action: "update", field: "system_prompt", value: "New system")

    assert_equal "config", result[:type]
    assert_equal "update", result[:action]
    assert_equal "New system", result[:value]
    assert_equal "New system", @agent.reload.system_prompt
  end

  test "update without value returns error" do
    result = @tool.execute(action: "update", field: "name")

    assert_equal "error", result[:type]
    assert_match(/value required/, result[:error])
    assert_includes result[:allowed_actions], "update"
  end

  test "update surfaces model validation errors" do
    other_agent = agents(:two)
    other_agent.update!(account: @agent.account)

    result = @tool.execute(action: "update", field: "name", value: other_agent.name)

    assert_equal "error", result[:type]
    assert_match(/taken/, result[:error])
  end

  test "invalid action returns self-correcting error" do
    result = @tool.execute(action: "delete", field: "name")

    assert_equal "error", result[:type]
    assert_match(/Invalid action/, result[:error])
    assert_equal %w[view update], result[:allowed_actions]
    assert_equal SelfAuthoringTool::FIELDS, result[:allowed_fields]
  end

  test "invalid field returns self-correcting error" do
    result = @tool.execute(action: "view", field: "bogus")

    assert_equal "error", result[:type]
    assert_match(/Invalid field/, result[:error])
    assert_equal SelfAuthoringTool::FIELDS, result[:allowed_fields]
  end

  test "returns error without group chat context" do
    tool = SelfAuthoringTool.new(chat: nil, current_agent: @agent)

    result = tool.execute(action: "view", field: "name")

    assert_equal "error", result[:type]
    assert_match(/group conversations/, result[:error])
  end

  test "returns error without agent context" do
    tool = SelfAuthoringTool.new(chat: @chat, current_agent: nil)

    result = tool.execute(action: "view", field: "name")

    assert_equal "error", result[:type]
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
    @tool.define_singleton_method(:searxng_instance_url) { "https://searxng.test" }
  end

  test "search returns results with type" do
    stub_searxng_success

    result = @tool.execute(action: "search", query: "rails")

    assert_equal "search_results", result[:type]
    assert_equal "rails", result[:query]
    assert result[:results].is_a?(Array)
  end

  test "search without query returns param error" do
    result = @tool.execute(action: "search")

    assert_equal "error", result[:type]
    assert_match(/query is required/, result[:error])
    assert_equal "query", result[:required_param]
  end

  test "search respects rate limit" do
    stub_searxng_success

    WebTool::MAX_SEARCHES_PER_SESSION.times do |i|
      result = @tool.execute(action: "search", query: "query #{i}")
      assert_nil result[:error]
    end

    result = @tool.execute(action: "search", query: "one too many")
    assert_equal "error", result[:type]
    assert_match(/limit reached/, result[:error])
  end

  test "fetch returns page content with type" do
    stub_request(:get, "https://example.com/")
      .to_return(status: 200, body: "<html><body>Hello</body></html>")

    result = @tool.execute(action: "fetch", url: "https://example.com")

    assert_equal "fetched_page", result[:type]
    assert_match(/Hello/, result[:content])
    assert result[:fetched_at].present?
  end

  test "fetch without url returns param error" do
    result = @tool.execute(action: "fetch")

    assert_equal "error", result[:type]
    assert_match(/url is required/, result[:error])
    assert_equal "url", result[:required_param]
  end

  test "fetch handles redirects" do
    stub_request(:get, "http://example.com/")
      .to_return(status: 301, headers: { "Location" => "https://example.com/" })

    result = @tool.execute(action: "fetch", url: "http://example.com")

    assert_equal "redirect", result[:type]
    assert_equal "https://example.com/", result[:redirect_url]
  end

  test "fetch rejects non-http urls" do
    result = @tool.execute(action: "fetch", url: "ftp://example.com")

    assert_equal "error", result[:type]
    assert_match(/Invalid URL/, result[:error])
  end

  test "invalid action returns self-correcting error" do
    result = @tool.execute(action: "crawl", query: "test")

    assert_equal "error", result[:type]
    assert_match(/Invalid action/, result[:error])
    assert_equal %w[search fetch], result[:allowed_actions]
  end

  private

  def stub_searxng_success
    stub_request(:get, /searxng/)
      .to_return(
        status: 200,
        body: { query: "test", number_of_results: 100, results: [
          { url: "https://a.com", title: "A", content: "Content A" },
          { url: "https://b.com", title: "B", content: "Content B" }
        ]}.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end
```

---

## Rollback Plan

If issues arise post-deployment:

1. Restore deleted tool files from git
2. Create inverse rake task:
   ```ruby
   namespace :tools do
     task deconsolidate: :environment do
       Agent.find_each do |agent|
         next if agent.enabled_tools.blank?

         expanded = agent.enabled_tools.flat_map do |tool|
           case tool
           when "SelfAuthoringTool"
             %w[ViewSystemPromptTool UpdateSystemPromptTool]
           when "WebTool"
             %w[WebSearchTool WebFetchTool]
           else
             tool
           end
         end.uniq

         agent.update!(enabled_tools: expanded)
       end
     end
   end
   ```
3. Remove new tool files

Git history preserves all original implementations.
