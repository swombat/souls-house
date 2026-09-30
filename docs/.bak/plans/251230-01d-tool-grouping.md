# Tool Grouping Implementation Plan - Iteration D (Scale-First)

## Executive Summary

This plan embraces domain-based tool consolidation as the architectural pattern for scaling to 50+ agent capabilities. Rather than fighting the polymorphic approach, we lean into it with clear guardrails: focused methods under 100 lines, direct attribute names without translation layers, and self-correcting error responses.

Two consolidated tools replace four:

1. **AgentConfigTool** - Manages all agent configuration (prompts, name, future: model, settings)
2. **WebTool** - Handles all web operations (search, fetch, future: extract)

The pattern established here scales: each domain tool accepts `action` + domain-specific parameters, routes to focused private methods, and returns structured responses with type discrimination.

---

## Architecture Overview

### The Scale Constraint

The core constraint is not Ruby elegance—it is LLM capability at scale. With 50+ capabilities incoming, the choice is:

| Approach | Tools at 50 capabilities | Context impact |
|----------|--------------------------|----------------|
| One tool per action | 50+ tools | Significant context bloat |
| Domain consolidation | 10-15 tools | Manageable context |

Domain consolidation wins. The Ruby code is slightly less beautiful. The agents are significantly more capable.

### Design Principles

1. **Action as first parameter** - Every consolidated tool starts with `action:`
2. **Direct attribute names** - No translation layers. `system_prompt` in the API means `system_prompt` on the model
3. **Self-correcting errors** - Validation failures return `allowed_actions` and valid values
4. **Under 100 lines** - Consolidation must not create God classes
5. **Type-discriminated responses** - Every response includes `type:` for branching

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

## Part 1: AgentConfigTool

### Why This Name

- `PromptManagerTool` implies only prompts. This tool manages prompts, name, and will extend to model selection, enabled tools, etc.
- `AgentConfigTool` accurately describes scope: agent configuration
- Matches the domain pattern: `WebTool`, `MemoryTool`, `AgentConfigTool`

### Schema

```ruby
class AgentConfigTool < RubyLLM::Tool

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
```

### Key Design Decisions

**Direct field names, no translation layer.** The requirements mentioned `conversation_consolidation` mapping to `reflection_prompt`. That is a translation layer. Per DHH's feedback: use actual attribute names everywhere. The LLM learns `reflection_prompt` once.

**Single field per call.** This is simpler than the previous iteration's multi-field update. One field, one action, one result. Simpler for LLMs to reason about.

**Field parameter, not prompt_type.** The tool manages more than prompts. `field` is accurate; `prompt_type` is not.

### Implementation

```ruby
class AgentConfigTool < RubyLLM::Tool

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
      value: @current_agent.public_send(field) || "(not set)",
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

**Line count: 68 lines.** Well under the 100-line guideline.

### Response Schema

All responses include `type:` for LLM branching:

```ruby
# View success
{ type: "config", action: "view", field: "system_prompt", value: "...", agent: "Sage" }

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

### The query_or_url Question

DHH acknowledged `query_or_url` is a code smell but acceptable for scale. Here is a cleaner alternative that maintains tool count reduction:

**Option A: `query_or_url` (original proposal)**
- Single parameter, interpreted by action
- Code smell: parameter meaning changes based on action
- Upside: minimal parameters

**Option B: `query` + `url` (separate optional params)**
- Two optional parameters, one required per action
- Cleaner semantics: `query` always means query, `url` always means URL
- Tool validates: search requires query, fetch requires url
- Self-correcting errors guide the LLM

**Recommendation: Option B.** The additional parameter is worth the semantic clarity. The tool validates and returns helpful errors if the LLM uses the wrong one.

### Schema

```ruby
class WebTool < RubyLLM::Tool

  ACTIONS = %w[search fetch].freeze

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

  # === Search ===

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

  # === Fetch ===

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

  # === Errors ===

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

**Line count: 98 lines.** Just under the guideline, and cleanly separated.

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

# HTTP/network error
{ type: "error", error: "HTTP 404: Not Found", url: "https://..." }
```

---

## Future Domain Tools (Pattern Examples)

The pattern established here extends naturally:

### MemoryTool (future)

```ruby
class MemoryTool < RubyLLM::Tool
  ACTIONS = %w[save recall search forget].freeze

  param :action, type: :string, required: true
  param :memory_type, type: :string  # core, journal
  param :content, type: :string
  param :query, type: :string

  def execute(action:, **params)
    send("#{action}_memory", **params)
  end
end
```

### TaskTool (future)

```ruby
class TaskTool < RubyLLM::Tool
  ACTIONS = %w[create update complete list].freeze

  param :action, type: :string, required: true
  param :task_id, type: :string
  param :title, type: :string
  param :status, type: :string

  def execute(action:, **params)
    send("#{action}_task", **params)
  end
end
```

At 50 capabilities, this pattern yields approximately 10 domain tools instead of 50 individual tools.

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
  - [ ] Test nil/blank field values return "(not set)"

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
        "ViewSystemPromptTool" => "AgentConfigTool",
        "UpdateSystemPromptTool" => "AgentConfigTool",
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

### AgentConfigTool Tests

```ruby
require "test_helper"

class AgentConfigToolTest < ActiveSupport::TestCase
  setup do
    @agent = agents(:one)
    @agent.update!(
      system_prompt: "Original system",
      reflection_prompt: "Original reflection",
      memory_reflection_prompt: "Original memory"
    )
    @chat = chats(:group_chat)
    @tool = AgentConfigTool.new(chat: @chat, current_agent: @agent)
  end

  # View tests

  test "view returns field value with type" do
    result = @tool.execute(action: "view", field: "system_prompt")

    assert_equal "config", result[:type]
    assert_equal "view", result[:action]
    assert_equal "system_prompt", result[:field]
    assert_equal "Original system", result[:value]
    assert_equal @agent.name, result[:agent]
  end

  test "view returns (not set) for nil values" do
    @agent.update!(system_prompt: nil)

    result = @tool.execute(action: "view", field: "system_prompt")

    assert_equal "(not set)", result[:value]
  end

  test "view works for all fields" do
    AgentConfigTool::FIELDS.each do |field|
      result = @tool.execute(action: "view", field: field)
      assert_equal "config", result[:type]
      assert_equal field, result[:field]
    end
  end

  # Update tests

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

  # Validation error tests

  test "invalid action returns self-correcting error" do
    result = @tool.execute(action: "delete", field: "name")

    assert_equal "error", result[:type]
    assert_match(/Invalid action/, result[:error])
    assert_equal %w[view update], result[:allowed_actions]
    assert_equal AgentConfigTool::FIELDS, result[:allowed_fields]
  end

  test "invalid field returns self-correcting error" do
    result = @tool.execute(action: "view", field: "bogus")

    assert_equal "error", result[:type]
    assert_match(/Invalid field/, result[:error])
    assert_equal AgentConfigTool::FIELDS, result[:allowed_fields]
  end

  # Context tests

  test "returns error without group chat context" do
    tool = AgentConfigTool.new(chat: nil, current_agent: @agent)

    result = tool.execute(action: "view", field: "name")

    assert_equal "error", result[:type]
    assert_match(/group conversations/, result[:error])
  end

  test "returns error without agent context" do
    tool = AgentConfigTool.new(chat: @chat, current_agent: nil)

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

  # Search tests

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

  # Fetch tests

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

  # Validation tests

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

## Documentation: Domain Tools Pattern

### /docs/domain-tools.md

```markdown
# Domain Tools Pattern

This document describes how Helix Kit consolidates agent capabilities into domain tools for scale.

## The Problem

LLMs have limited context windows and attention. An agent with access to 50 individual tools experiences:

- Context bloat from 50 tool definitions
- Reduced attention for each tool
- Harder time selecting the right tool

## The Solution: Domain Consolidation

Group related capabilities into domain tools with action parameters:

| Individual Tools | Domain Tool |
|------------------|-------------|
| view_prompt, update_prompt, view_name, update_name | `agent_config(action, field, value)` |
| web_search, web_fetch | `web(action, query, url)` |
| save_memory, recall_memory, forget_memory | `memory(action, ...)` |

At 50 capabilities, this reduces tool count from 50 to approximately 10.

## Pattern Structure

Every domain tool follows this structure:

```ruby
class DomainTool < RubyLLM::Tool
  ACTIONS = %w[action_one action_two].freeze

  param :action, type: :string, required: true
  # Additional domain-specific params

  def execute(action:, **params)
    return validation_error(action) unless ACTIONS.include?(action)
    send("#{action}_action", **params)
  end

  private

  def action_one_action(**params)
    # Focused implementation
  end

  def validation_error(message)
    { type: "error", error: message, allowed_actions: ACTIONS }
  end
end
```

## Response Conventions

All responses include `type:` for reliable branching:

- Success: `{ type: "specific_result_type", ... }`
- Error: `{ type: "error", error: "...", allowed_actions: [...] }`

Validation errors are self-correcting: they include the valid options so LLMs can retry without additional context.

## Adding Capabilities

### To add a new action to an existing domain:

1. Add to `ACTIONS` constant
2. Add private method `{action}_action`
3. Update description
4. Add tests

### To create a new domain tool:

1. Identify related capabilities (3+ is a good threshold)
2. Create tool following the pattern
3. Keep under 100 lines
4. Include self-correcting errors
5. Add comprehensive tests

## Current Domain Tools

### AgentConfigTool

Manages agent configuration.

- **Actions**: view, update
- **Fields**: name, system_prompt, reflection_prompt, memory_reflection_prompt

### WebTool

Web search and page fetching.

- **Actions**: search, fetch
- **Params**: query (for search), url (for fetch)

## Guidelines

1. **Keep tools under 100 lines** - Extract if growing too large
2. **Direct attribute names** - No translation layers
3. **Self-correcting errors** - Include valid options on failure
4. **Type-discriminated responses** - Always include `type:`
5. **Focused methods** - Each action method should do one thing
```

---

## Rollback Plan

If issues arise post-deployment:

1. Restore deleted tool files from git
2. Create inverse rake task:
   ```ruby
   namespace :tools do
     task deconsolidate: :environment do
       # Expand back to individual tools
       Agent.find_each do |agent|
         next if agent.enabled_tools.blank?

         expanded = agent.enabled_tools.flat_map do |tool|
           case tool
           when "AgentConfigTool"
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

---

## Summary

This iteration embraces scale-first thinking:

1. **AgentConfigTool** consolidates prompt/name management with direct field names
2. **WebTool** consolidates search/fetch with separate `query` and `url` params (cleaner than `query_or_url`)
3. **Self-correcting errors** help LLMs recover without round-trips
4. **Under 100 lines** each, with focused private methods
5. **Pattern scales** to 50+ capabilities in ~10 domain tools

The Ruby is slightly less beautiful. The agents are significantly more capable.
